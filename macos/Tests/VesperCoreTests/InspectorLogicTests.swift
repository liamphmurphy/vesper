import XCTest
@testable import VesperCore

final class InspectorLogicTests: XCTestCase {
    private func sampleModel(
        open: Bool = true,
        activeTabId: String = "properties",
        tabs: [InspectorTab]? = nil
    ) -> InspectorModel {
        let defaultTabs = [
            InspectorTab(id: "properties", label: "Properties", icon: "sliders", kind: .native),
            InspectorTab(id: "chat", label: "Chat", icon: "msg", kind: .companion),
            InspectorTab(id: "design", label: "Design", icon: "designs", kind: .web),
        ]
        return InspectorModel(id: "ticket", open: open, activeTabId: activeTabId, tabs: tabs ?? defaultTabs)
    }

    func testActiveTabFindsSelectedOrFallsBackToFirst() {
        let model = sampleModel(activeTabId: "chat")
        XCTAssertEqual(InspectorLogic.activeTab(in: model)?.id, "chat")

        let missing = sampleModel(activeTabId: "nonexistent")
        XCTAssertEqual(InspectorLogic.activeTab(in: missing)?.id, "properties")

        let empty = sampleModel(activeTabId: "chat", tabs: [])
        XCTAssertNil(InspectorLogic.activeTab(in: empty))
        XCTAssertNil(InspectorLogic.activeTab(in: nil))
    }

    func testShouldShowNativeInspector() {
        XCTAssertTrue(InspectorLogic.shouldShowNativeInspector(model: sampleModel(open: true, activeTabId: "properties")))
        XCTAssertTrue(InspectorLogic.shouldShowNativeInspector(model: sampleModel(open: true, activeTabId: "chat")))
        XCTAssertFalse(InspectorLogic.shouldShowNativeInspector(model: sampleModel(open: true, activeTabId: "design")))
        XCTAssertFalse(InspectorLogic.shouldShowNativeInspector(model: sampleModel(open: false, activeTabId: "properties")))
        XCTAssertFalse(InspectorLogic.shouldShowNativeInspector(model: sampleModel(open: true, activeTabId: "properties"), poppedOut: true))
        XCTAssertFalse(InspectorLogic.shouldShowNativeInspector(model: nil))
    }

    func testHandlesToggleNatively() {
        XCTAssertTrue(InspectorLogic.handlesToggleNatively(model: sampleModel(open: false, activeTabId: "properties")))
        XCTAssertTrue(InspectorLogic.handlesToggleNatively(model: sampleModel(open: true, activeTabId: "chat")))
        XCTAssertFalse(InspectorLogic.handlesToggleNatively(model: sampleModel(open: true, activeTabId: "design")))
        XCTAssertFalse(InspectorLogic.handlesToggleNatively(model: sampleModel(open: true, activeTabId: "properties"), poppedOut: true))
        XCTAssertFalse(InspectorLogic.handlesToggleNatively(model: nil))
    }

    func testIsNativeTab() {
        let model = sampleModel()
        XCTAssertTrue(InspectorLogic.isNativeTab("properties", in: model))
        XCTAssertTrue(InspectorLogic.isNativeTab("chat", in: model))
        XCTAssertFalse(InspectorLogic.isNativeTab("design", in: model))
        XCTAssertFalse(InspectorLogic.isNativeTab("unknown", in: model))
        XCTAssertFalse(InspectorLogic.isNativeTab("properties", in: nil))
    }

    func testInspectorDividerIndexAndRailTabExtraction() {
        XCTAssertEqual(InspectorLogic.inspectorDividerIndex(hasSidebar: true), 1)
        XCTAssertEqual(InspectorLogic.inspectorDividerIndex(hasSidebar: false), 0)

        XCTAssertEqual(InspectorLogic.railDockTabId(from: "dock.tab:chat"), "chat")
        XCTAssertEqual(InspectorLogic.railDockTabId(from: "dock.tab:properties"), "properties")
        XCTAssertNil(InspectorLogic.railDockTabId(from: "dock.tab:"))
        XCTAssertNil(InspectorLogic.railDockTabId(from: "dock.toggle"))
        XCTAssertNil(InspectorLogic.railDockTabId(from: "settings"))
    }
}
