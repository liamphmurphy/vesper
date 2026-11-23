import XCTest
@testable import VesperCore

final class SpacesLogicTests: XCTestCase {
    func testSuggestWorkKeyAndValidation() {
        XCTAssertEqual(SpacesLogic.suggestWorkKey(for: "Waterdeep campaign"), "WC")
        XCTAssertEqual(SpacesLogic.suggestWorkKey(for: "Homelab"), "HOME")
        XCTAssertEqual(SpacesLogic.suggestWorkKey(for: "A"), "AX")
        XCTAssertEqual(SpacesLogic.suggestWorkKey(for: "123"), "")

        XCTAssertTrue(SpacesLogic.isValidWorkKey("PAY"))
        XCTAssertTrue(SpacesLogic.isValidWorkKey("LAZYAGENTS"))
        XCTAssertFalse(SpacesLogic.isValidWorkKey("A"))
        XCTAssertFalse(SpacesLogic.isValidWorkKey("1ABC"))
        XCTAssertFalse(SpacesLogic.isValidWorkKey("TOO_LONG_KEY"))
    }

    func testTokensBareURLAndInitial() {
        XCTAssertEqual(SpacesLogic.initial(for: "  health"), "H")
        XCTAssertEqual(SpacesLogic.initial(for: "!!!"), "#")
        XCTAssertEqual(SpacesLogic.formatTokens(950), "950")
        XCTAssertEqual(SpacesLogic.formatTokens(1240), "1.2k")
        XCTAssertEqual(SpacesLogic.formatTokens(13100), "13k")
        XCTAssertEqual(SpacesLogic.formatTokens(13100, precise: true), "13.1k")
        XCTAssertEqual(SpacesLogic.bareURL("https://www.examine.com/creatine/"), "examine.com/creatine")
    }

    func testNavModelListsSpacesAndDecodesCommands() {
        let sp = API.ChatSpace(
            chatCount: 4,
            color: .teal,
            connectorIds: [],
            createdAt: "2026-11-20T00:00:00Z",
            description: "Campaign notes",
            id: "sp-1",
            inlineTokens: 0,
            instructions: "",
            memoryCount: 0,
            name: "Umbra",
            sourceCount: 1,
            spaceMemory: true,
            updatedAt: "2026-11-20T00:00:00Z"
        )
        let nav = SpacesLogic.navModel(spaces: [sp], activeSpaceId: "sp-1")
        XCTAssertEqual(nav.id, SpacesLogic.navId)
        XCTAssertEqual(nav.selectedId, "space:sp-1")
        XCTAssertEqual(nav.actions?.map(\.id), [SpacesLogic.backToChatAction, SpacesLogic.newSpaceAction])
        XCTAssertEqual(nav.sections.first?.items.first?.trailing, "4")

        XCTAssertEqual(
            SpacesLogic.navAction(for: .navAction(navigatorId: SpacesLogic.navId, actionId: SpacesLogic.backToChatAction)),
            .backToChat
        )
        XCTAssertEqual(
            SpacesLogic.navAction(for: .navAction(navigatorId: SpacesLogic.navId, actionId: SpacesLogic.newSpaceAction)),
            .newSpace
        )
        XCTAssertEqual(
            SpacesLogic.navAction(for: .navActivate(navigatorId: SpacesLogic.navId, itemId: "space:sp-1", newTab: true)),
            .openSpace("sp-1", newTab: true)
        )
        XCTAssertEqual(
            SpacesLogic.navAction(for: .navActivate(navigatorId: SpacesLogic.navId, itemId: "chat:c-9", newTab: false)),
            .openChat("c-9", newTab: false)
        )
    }
}
