import XCTest
@testable import VesperCore

final class BridgeProtocolTests: XCTestCase {
    /// <repo>/protocol/native-bridge, found from this file's path.
    static var fixtureDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("protocol/native-bridge")
    }

    private func entries(_ name: String) throws -> [Any] {
        let data = try Data(contentsOf: Self.fixtureDir.appendingPathComponent(name))
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [Any])
    }

    func testEveryPageMessageFixtureDecodes() throws {
        let all = try entries("page-messages.json")
        XCTAssertGreaterThanOrEqual(all.count, 12)
        for entry in all {
            XCTAssertNoThrow(try PageMessage.decode(fromJSONObject: entry), "\(entry)")
        }
    }

    func testPageMessageDetails() throws {
        let all = try entries("page-messages.json").map { try PageMessage.decode(fromJSONObject: $0) }
        XCTAssertEqual(all[0], .ready(path: "/work"))
        XCTAssertEqual(all[1], .route(path: "/tickets/VES-412", area: .work))
        XCTAssertEqual(all[2], .route(path: "/settings", area: nil))
        guard case .shell(let shell) = all[4] else { return XCTFail("shell") }
        XCTAssertEqual(shell.areas.count, 4)
        XCTAssertEqual(shell.currentArea, .work)
        XCTAssertEqual(shell.areas[2].badge?.text, "3")
        guard case .navigator(let nav?) = all[5] else { return XCTFail("navigator") }
        XCTAssertEqual(nav.sections.count, 2)
        XCTAssertEqual(nav.sections[0].items[0].children?.first?.contextMenu?.count, 2)
        XCTAssertEqual(nav.selectedId, "p2")
        XCTAssertEqual(all[6], .navigator(nil))
        XCTAssertEqual(nav.actions?[1].disabled, true)
        XCTAssertEqual(nav.filters?.count, 2)
        XCTAssertEqual(nav.filters?[0].options[1].checked, true)
        XCTAssertEqual(nav.filters?[1].multiple, true)
        XCTAssertEqual(nav.sections[0].badge, NavBadge(text: "3", tone: .neutral))
        XCTAssertEqual(nav.sections[1].actions?[0].showsLabel, true)
        XCTAssertNil(nav.actions?[0].showsLabel)
        XCTAssertTrue(all.contains(.appearance(mode: .dark)))
        XCTAssertTrue(all.contains(.appearance(mode: .light, background: "#f5f5f7")))
        XCTAssertEqual(nav.sections[0].items[1].avatar?.color, "#9B8CFF")
        XCTAssertTrue(all.contains(.confirm(requestId: "r4", title: "Delete \u{201C}Weekly plan\u{201D}?", body: "This can\u{2019}t be undone.",
                                            confirmLabel: "Delete", cancelLabel: "Keep", destructive: true)))
        XCTAssertTrue(all.contains(.confirm(requestId: "r5", title: "Approve all 3 requests?", body: nil,
                                            confirmLabel: "Approve all", cancelLabel: nil, destructive: false)))
    }

    func testInspectorAndOpenInMainMessages() throws {
        let all = try entries("page-messages.json").map { try PageMessage.decode(fromJSONObject: $0) }
        XCTAssertTrue(all.contains(.inspector(nil)))
        XCTAssertTrue(all.contains(.openInMain(path: "/tickets/VES-412", newTab: true)))

        let inspectorModels = all.compactMap { msg -> InspectorModel? in
            if case .inspector(let model?) = msg { return model }
            return nil
        }
        let model = try XCTUnwrap(inspectorModels.first)
        XCTAssertEqual(model.id, "ticket:VES-412")
        XCTAssertTrue(model.open)
        XCTAssertEqual(model.activeTabId, "properties")
        XCTAssertEqual(model.companion?.subject?.kind, .ticket)
        XCTAssertEqual(model.companion?.subject?.id, "VES-412")
        XCTAssertEqual(model.tabs.map(\.kind), [.native, .companion, .web])
        XCTAssertEqual(model.tabs[0].sections?.first?.items.count, 12)
        XCTAssertEqual(model.tabs[0].sections?.first?.items[5].steps?.last?.state, .needsHuman)

        let panelModel = try XCTUnwrap(inspectorModels.dropFirst().first)
        XCTAssertEqual(panelModel.id, "chat:c1")
        XCTAssertEqual(panelModel.tabs.first?.kind, .panel)
        XCTAssertEqual(panelModel.tabs.first?.width, .wide)
        XCTAssertEqual(panelModel.tabs.first?.panel?.kind, "chat.playground")
        XCTAssertEqual(panelModel.tabs.first?.panel?.key, "chat.playground:c1")
        XCTAssertTrue(all.contains(.panelEvent(tabId: "playground", event: "fullscreen", payloadJson: nil)))
    }

    func testEveryCommandFixtureRoundTrips() throws {
        let all = try entries("native-commands.json")
        XCTAssertGreaterThanOrEqual(all.count, 10)
        for entry in all {
            let data = try JSONSerialization.data(withJSONObject: entry)
            let cmd = try JSONDecoder().decode(NativeCommand.self, from: data)
            let out = try JSONSerialization.jsonObject(with: JSONEncoder().encode(cmd))
            XCTAssertEqual(out as? NSDictionary, entry as? NSDictionary, "\(entry)")
        }
    }

    func testRejectsUnknownTypeAndVersion() {
        XCTAssertThrowsError(try PageMessage.decode(fromJSONObject: ["v": 1, "type": "nope"]))
        XCTAssertThrowsError(try PageMessage.decode(fromJSONObject: ["v": 2, "type": "ready", "path": "/"]))
    }

    func testFilterAndAppearanceCommandsEncode() throws {
        let filter = try NativeCommand.navFilter(navigatorId: "work", filterId: "space", value: "VES", checked: true).jsonString()
        XCTAssertTrue(filter.contains("\"type\":\"nav.filter\""))
        XCTAssertTrue(filter.contains("\"checked\":true"))
        let appearance = try NativeCommand.appearance(accent: "#0A84FF", mode: .dark).jsonString()
        XCTAssertTrue(appearance.contains("\"accent\":\"#0A84FF\""))
        XCTAssertTrue(appearance.contains("\"mode\":\"dark\""))
    }

    func testReplyEncodesNullSelection() throws {
        let json = try NativeCommand.reply(requestId: "a", ok: true, selectedId: .some(nil)).jsonString()
        XCTAssertTrue(json.contains("\"selectedId\":null"))
        XCTAssertFalse(try NativeCommand.reply(requestId: "a", ok: true).jsonString().contains("selectedId"))
    }

    func testInspectorCommandsEncode() throws {
        let vis = try NativeCommand.inspectorVisibility(open: false).jsonString()
        XCTAssertTrue(vis.contains("\"type\":\"inspector.visibility\""))
        XCTAssertTrue(vis.contains("\"open\":false"))

        let tab = try NativeCommand.inspectorSelectTab(tabId: "chat").jsonString()
        XCTAssertTrue(tab.contains("\"type\":\"inspector.selectTab\""))
        XCTAssertTrue(tab.contains("\"tabId\":\"chat\""))

        let act = try NativeCommand.inspectorAction(tabId: "properties", actionId: "labels", itemId: "l1", menuItemId: "toggle:l1").jsonString()
        XCTAssertTrue(act.contains("\"type\":\"inspector.action\""))
        XCTAssertTrue(act.contains("\"menuItemId\":\"toggle:l1\""))

        let change = try NativeCommand.inspectorChange(tabId: "properties", fieldId: "status", value: "done").jsonString()
        XCTAssertTrue(change.contains("\"type\":\"inspector.change\""))

        let toggle = try NativeCommand.inspectorToggle(tabId: "properties", fieldId: "mockup", checked: true).jsonString()
        XCTAssertTrue(toggle.contains("\"type\":\"inspector.toggle\""))

        let ctx = try NativeCommand.companionContext(CompanionContext(
            subject: CompanionSubject(kind: .run, id: "r1", title: "Run", agent: "Implementer", ticketKey: "VES-1"),
            path: "/runs/r1"
        )).jsonString()
        XCTAssertTrue(ctx.contains("\"type\":\"companion.context\""))
        XCTAssertTrue(ctx.contains("\"ticketKey\":\"VES-1\""))

        let emptyPanelCtx = try NativeCommand.panelContext(InspectorPanelContext(active: nil, keepKeys: [])).jsonString()
        XCTAssertTrue(emptyPanelCtx.contains("\"type\":\"panel.context\""))
        XCTAssertTrue(emptyPanelCtx.contains("\"active\":null"))

        let panelEvt = try NativeCommand.panelEvent(tabId: "code", event: "fullscreen", payloadJson: "{}").jsonString()
        XCTAssertTrue(panelEvt.contains("\"type\":\"panel.event\""))
        XCTAssertTrue(panelEvt.contains("\"tabId\":\"code\""))
    }
}

final class BridgeOriginTests: XCTestCase {
    let base = URL(string: "http://127.0.0.1:8080")!

    func testMatches() {
        XCTAssertTrue(BridgeOrigin.matches(scheme: "http", host: "127.0.0.1", port: 8080, base: base))
        XCTAssertTrue(BridgeOrigin.matches(scheme: "http", host: "localhost", port: 8080, base: base))
        XCTAssertTrue(BridgeOrigin.matches(scheme: "http", host: "::1", port: 8080, base: base))
        XCTAssertFalse(BridgeOrigin.matches(scheme: "http", host: "127.0.0.1", port: 8090, base: base))
        XCTAssertFalse(BridgeOrigin.matches(scheme: "https", host: "127.0.0.1", port: 8080, base: base))
        XCTAssertFalse(BridgeOrigin.matches(scheme: "http", host: "evil.example", port: 8080, base: base))
    }

    func testDefaultPorts() {
        let https = URL(string: "https://vesper.example")!
        XCTAssertTrue(BridgeOrigin.matches(scheme: "https", host: "vesper.example", port: 0, base: https))
        XCTAssertTrue(BridgeOrigin.matches(scheme: "https", host: "vesper.example", port: 443, base: https))
        XCTAssertFalse(BridgeOrigin.matches(scheme: "https", host: "vesper.example", port: 8443, base: https))
    }

    func testURLForm() {
        XCTAssertTrue(BridgeOrigin.matches(url: URL(string: "http://localhost:8080/chat")!, base: base))
        XCTAssertFalse(BridgeOrigin.matches(url: URL(string: "http://localhost:8091/chat")!, base: base))
    }
}
