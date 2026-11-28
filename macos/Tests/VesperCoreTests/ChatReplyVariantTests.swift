import XCTest
@testable import VesperCore

final class ChatReplyVariantTests: XCTestCase {
    func testArchiveAndCycleVariants() {
        var store = ChatReplyVariantStore()
        let v1 = ChatReplyVariant(id: "m1", bodyMd: "First take", model: "opus")
        let v2 = ChatReplyVariant(id: "m2", bodyMd: "Second take", model: "sonnet")

        // Before regenerating: only the live reply exists
        let initial = store.variants(chatId: "c1", userMessageId: "u1", liveReply: v1)
        XCTAssertEqual(initial.items.count, 1)
        XCTAssertEqual(initial.activeIndex, 0)

        // Archive v1, then v2 arrives as live reply
        store.archiveBeforeRegenerate(chatId: "c1", userMessageId: "u1", reply: v1)
        let after = store.variants(chatId: "c1", userMessageId: "u1", liveReply: v2)
        XCTAssertEqual(after.items.map(\.id), ["m1", "m2"])
        XCTAssertEqual(after.activeIndex, 1)

        // Switching back to v1 selects index 0
        store.select(chatId: "c1", userMessageId: "u1", index: 0)
        let switched = store.variants(chatId: "c1", userMessageId: "u1", liveReply: v2)
        XCTAssertEqual(switched.activeIndex, 0)
        XCTAssertEqual(switched.items[switched.activeIndex].bodyMd, "First take")

        // Clearing removes only that chat's variants
        store.archiveBeforeRegenerate(chatId: "c2", userMessageId: "u9", reply: v1)
        store.clear(chatId: "c1")
        XCTAssertEqual(store.variants(chatId: "c1", userMessageId: "u1", liveReply: v2).items.count, 1)
        XCTAssertEqual(store.variants(chatId: "c2", userMessageId: "u9", liveReply: v2).items.count, 2)
    }
}
