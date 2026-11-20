import XCTest
@testable import VesperCore

final class ShortcutsCatalogTests: XCTestCase {
    func testCatalogCoversExpectedSections() {
        let titles = KeyboardShortcutsCatalog.allSections.map(\.title)
        XCTAssertTrue(titles.contains("Global"))
        XCTAssertTrue(titles.contains("Palette"))
        XCTAssertTrue(titles.contains("Knowledge"))
        XCTAssertFalse(KeyboardShortcutsCatalog.allSections.contains { $0.items.isEmpty })
    }

    func testFilterMatchesSectionLabelAndKeys() {
        XCTAssertEqual(KeyboardShortcutsCatalog.filter(query: "   "), KeyboardShortcutsCatalog.allSections)

        let knowledge = KeyboardShortcutsCatalog.filter(query: "knowledge")
        XCTAssertEqual(knowledge.map(\.title), ["Knowledge"])

        let paletteMatches = KeyboardShortcutsCatalog.filter(query: "Attach to a chat")
        XCTAssertEqual(paletteMatches.first?.items.first?.keys, ["⌥", "↵"])

        let none = KeyboardShortcutsCatalog.filter(query: "definitely-nonexistent-shortcut")
        XCTAssertTrue(none.isEmpty)
    }
}
