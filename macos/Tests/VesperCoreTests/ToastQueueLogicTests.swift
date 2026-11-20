import XCTest
@testable import VesperCore

final class ToastQueueLogicTests: XCTestCase {
    func testUpsertReplacesExistingInPlaceAndCapsOverflow() {
        var list: [ToastItemModel] = []
        for i in 1...3 {
            let res = ToastQueueLogic.upsert(ToastItemModel(id: "t\(i)", title: "Toast \(i)"), into: list)
            list = res.visible
            XCTAssertTrue(res.evicted.isEmpty)
        }

        let replaced = ToastQueueLogic.upsert(ToastItemModel(id: "t2", title: "Updated 2"), into: list)
        list = replaced.visible
        XCTAssertEqual(list.map(\.id), ["t1", "t2", "t3"])
        XCTAssertEqual(list[1].title, "Updated 2")
        XCTAssertTrue(replaced.evicted.isEmpty)

        let overflowed = ToastQueueLogic.upsert(ToastItemModel(id: "t4", title: "Toast 4"), into: list)
        XCTAssertEqual(overflowed.visible.map(\.id), ["t2", "t3", "t4"])
        XCTAssertEqual(overflowed.evicted.map(\.id), ["t1"])
    }

    func testRemoveRemovesMatchingIdOnly() {
        let initial = [ToastItemModel(id: "a", title: "A"), ToastItemModel(id: "b", title: "B")]
        let miss = ToastQueueLogic.remove(id: "c", from: initial)
        XCTAssertNil(miss.removed)
        XCTAssertEqual(miss.visible, initial)

        let hit = ToastQueueLogic.remove(id: "a", from: initial)
        XCTAssertEqual(hit.removed?.id, "a")
        XCTAssertEqual(hit.visible.map(\.id), ["b"])
    }
}
