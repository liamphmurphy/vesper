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
        let model = sampleModel(tabs: [
            InspectorTab(id: "properties", label: "Properties", icon: "sliders", kind: .native),
            InspectorTab(id: "chat", label: "Chat", icon: "msg", kind: .companion),
            InspectorTab(id: "playground", label: "Playground", icon: "playLeft", kind: .panel, width: .wide),
            InspectorTab(id: "design", label: "Design", icon: "designs", kind: .web),
        ])
        XCTAssertTrue(InspectorLogic.isNativeTab("properties", in: model))
        XCTAssertTrue(InspectorLogic.isNativeTab("chat", in: model))
        XCTAssertTrue(InspectorLogic.isNativeTab("playground", in: model))
        XCTAssertFalse(InspectorLogic.isNativeTab("design", in: model))
        XCTAssertFalse(InspectorLogic.isNativeTab("unknown", in: model))
        XCTAssertFalse(InspectorLogic.isNativeTab("properties", in: nil))
        XCTAssertTrue(InspectorLogic.shouldShowNativeInspector(model: sampleModel(open: true, activeTabId: "playground", tabs: model.tabs)))
        XCTAssertTrue(InspectorLogic.handlesToggleNatively(model: sampleModel(open: false, activeTabId: "playground", tabs: model.tabs)))
    }

    func testThicknessPopoutAndDesiredWidth() {
        let reg = InspectorLogic.thickness(for: nil)
        XCTAssertEqual(reg, InspectorLogic.InspectorThickness(min: 280, max: 640, preferred: 360))
        let wide = InspectorLogic.thickness(for: .wide)
        XCTAssertEqual(wide, InspectorLogic.InspectorThickness(min: 360, max: 960, preferred: 540))
        let max = InspectorLogic.thickness(for: .max)
        XCTAssertEqual(max, InspectorLogic.InspectorThickness(min: 420, max: 1120, preferred: 760))

        XCTAssertEqual(InspectorLogic.popoutSize(for: .regular).width, 380)
        XCTAssertEqual(InspectorLogic.popoutSize(for: .wide).width, 560)
        XCTAssertEqual(InspectorLogic.popoutSize(for: .max).width, 740)

        XCTAssertEqual(InspectorLogic.desiredWidth(for: .wide, availableWidth: 1200), 540)
        XCTAssertEqual(InspectorLogic.desiredWidth(for: .max, availableWidth: 1000, minContentWidth: 380), 620)
        XCTAssertEqual(InspectorLogic.desiredWidth(for: .wide, availableWidth: 600, minContentWidth: 380), 360)
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

    func testEffectiveInspectorFallsBackToDefaultCompanionOnNativeScreens() {
        let custom = sampleModel(open: true, activeTabId: "properties")
        let page = sampleModel(open: false, activeTabId: "design")

        // Native screen with no custom inspector gets the native default companion (never nil).
        let fallback = InspectorLogic.effectiveInspector(
            nativeActive: true,
            nativeInspector: nil,
            pageInspector: nil,
            defaultCompanionOpen: true,
            path: "/chat/abc"
        )
        XCTAssertEqual(fallback?.id, InspectorLogic.defaultCompanionModelId)
        XCTAssertEqual(fallback?.open, true)
        XCTAssertEqual(fallback?.activeTabId, InspectorLogic.defaultCompanionTabId)
        XCTAssertEqual(fallback?.tabs.map(\.kind), [.companion])
        XCTAssertEqual(fallback?.companion?.path, "/chat/abc")

        // Native screen with its own inspector wins over the default companion and page inspector.
        let own = InspectorLogic.effectiveInspector(
            nativeActive: true,
            nativeInspector: custom,
            pageInspector: page,
            defaultCompanionOpen: false,
            path: "/tickets/PAY-1"
        )
        XCTAssertEqual(own, custom)

        // Web screen keeps pageInspector (including nil when the page exposes none).
        XCTAssertEqual(
            InspectorLogic.effectiveInspector(
                nativeActive: false,
                nativeInspector: nil,
                pageInspector: page,
                defaultCompanionOpen: true,
                path: "/apps/designs"
            ),
            page
        )
        XCTAssertNil(
            InspectorLogic.effectiveInspector(
                nativeActive: false,
                nativeInspector: nil,
                pageInspector: nil,
                defaultCompanionOpen: true,
                path: "/apps/designs"
            )
        )
    }
}
