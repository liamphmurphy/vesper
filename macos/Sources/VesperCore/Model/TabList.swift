import Foundation

/// An ordered list of tabs with one active tab: the pure bookkeeping behind a compact-layout
/// window (which tab is selected after a close, reordering, "close others", wrap-around
/// next/previous). Index based so any element type works; the window keeps the real tab objects.
public struct TabList<Element> {
    public private(set) var items: [Element]
    public private(set) var activeIndex: Int

    public init(items: [Element] = [], activeIndex: Int = 0) {
        self.items = items
        self.activeIndex = items.isEmpty ? 0 : min(max(activeIndex, 0), items.count - 1)
    }

    public var count: Int { items.count }
    public var isEmpty: Bool { items.isEmpty }
    public var active: Element? { items.indices.contains(activeIndex) ? items[activeIndex] : nil }

    /// Adds a tab at `index` (clamped; the end when nil). `select` makes it the active tab.
    @discardableResult
    public mutating func insert(_ item: Element, at index: Int? = nil, select: Bool = true) -> Int {
        let i = min(max(index ?? items.count, 0), items.count)
        items.insert(item, at: i)
        if select || items.count == 1 {
            activeIndex = i
        } else if i <= activeIndex {
            activeIndex += 1
        }
        return i
    }

    /// Adds a tab right after the active one (what ⌘T and links do).
    @discardableResult
    public mutating func insertAfterActive(_ item: Element, select: Bool = true) -> Int {
        insert(item, at: items.isEmpty ? 0 : activeIndex + 1, select: select)
    }

    public mutating func select(_ index: Int) {
        if items.indices.contains(index) { activeIndex = index }
    }

    /// Removes a tab. Closing the active tab selects its right neighbour, else the new last tab;
    /// closing another tab keeps the active tab selected.
    @discardableResult
    public mutating func remove(at index: Int) -> Element? {
        guard items.indices.contains(index) else { return nil }
        let removed = items.remove(at: index)
        if items.isEmpty {
            activeIndex = 0
        } else if index < activeIndex {
            activeIndex -= 1
        } else if index == activeIndex {
            activeIndex = min(index, items.count - 1)
        }
        return removed
    }

    /// Moves a tab to `destination` (an index in the resulting list); the active tab follows its tab.
    public mutating func move(from source: Int, to destination: Int) {
        guard items.indices.contains(source) else { return }
        let target = min(max(destination, 0), items.count - 1)
        guard target != source else { return }
        let activeItemIndex = activeIndex
        let item = items.remove(at: source)
        items.insert(item, at: target)
        if activeItemIndex == source {
            activeIndex = target
        } else if source < activeItemIndex, target >= activeItemIndex {
            activeIndex = activeItemIndex - 1
        } else if source > activeItemIndex, target <= activeItemIndex {
            activeIndex = activeItemIndex + 1
        }
    }

    /// Indexes of every tab except `index`.
    public func indicesOfOthers(than index: Int) -> [Int] { items.indices.filter { $0 != index } }

    /// Indexes of the tabs after `index`.
    public func indicesToTheRight(of index: Int) -> [Int] {
        guard index + 1 < items.count else { return [] }
        return Array((index + 1)..<items.count)
    }

    public mutating func selectNext() {
        if items.count > 1 { activeIndex = (activeIndex + 1) % items.count }
    }

    public mutating func selectPrevious() {
        if items.count > 1 { activeIndex = (activeIndex - 1 + items.count) % items.count }
    }

    /// ⌘1–8 select that tab, ⌘9 the last one. Returns false when there is no such tab.
    @discardableResult
    public mutating func selectNumbered(_ n: Int) -> Bool {
        let target = n == 9 ? items.count - 1 : n - 1
        guard items.indices.contains(target) else { return false }
        activeIndex = target
        return true
    }
}

/// What closing one tab does. Closing the app's only tab leaves Vesper open on a new chat with the
/// default persona instead of closing its last window, which can quit the app.
public enum TabCloseOutcome: Equatable, Sendable {
    /// Take the tab out; its window keeps its other tabs.
    case removeTab
    /// The window's last tab, with another window still open: close the window.
    case closeWindow
    /// The app's only tab: put a new chat with the default persona in its place.
    case openNewChat

    /// `tabsInWindow`: tabs in the closing tab's window. `otherWindows`: the app's other open
    /// windows (in the separate layout each tab is a window, so this counts its sibling tabs too).
    public static func decide(tabsInWindow: Int, otherWindows: Int) -> TabCloseOutcome {
        if tabsInWindow > 1 { return .removeTab }
        return otherWindows > 0 ? .closeWindow : .openNewChat
    }
}

/// session.json for one window's tabs: the tabs that can be restored (their URLs; nil for a tab
/// that can't, such as a playground), the active one among them, and the window's bounds. nil when
/// there is nothing to save. An active tab that can't be saved is replaced by the next saved one.
public func sessionState(urls: [String?], activeIndex: Int, bounds: WindowBounds?) -> SessionState? {
    let saved = urls.compactMap { $0 }
    if saved.isEmpty { return nil }
    let before = urls.prefix(max(0, activeIndex)).compactMap { $0 }.count
    return SessionState(tabs: saved, activeIndex: min(before, saved.count - 1), bounds: bounds)
}

/// Live background activity badge shown in the compact toolbar tab strip.
public enum TabActivityStatus: String, Equatable, Hashable, Sendable {
    case running
    case needsAttention
    case unread
}

/// Pure status, tooltip, and horizontal overflow fade rules for `TabStripView`.
public enum TabStripLogic: Sendable {
    public struct Overflow: Equatable, Sendable {
        public var leading: Bool
        public var trailing: Bool

        public init(leading: Bool = false, trailing: Bool = false) {
            self.leading = leading
            self.trailing = trailing
        }
    }

    public static func overflow(
        contentWidth: Double,
        containerWidth: Double,
        contentOffsetX: Double,
        threshold: Double = 4
    ) -> Overflow {
        guard contentWidth > containerWidth + threshold else {
            return Overflow(leading: false, trailing: false)
        }
        let leading = contentOffsetX > threshold
        let trailing = (contentOffsetX + containerWidth) < (contentWidth - threshold)
        return Overflow(leading: leading, trailing: trailing)
    }

    public static func tooltip(
        title: String,
        activity: TabActivityStatus?,
        isActive: Bool
    ) -> String {
        switch activity {
        case .running:
            return "\(title) — Running"
        case .needsAttention:
            return "\(title) — Needs attention"
        case .unread where !isActive:
            return "\(title) — Unread"
        default:
            return title
        }
    }

    public static func chatTabActivity(
        state: API.ChatState?,
        unread: Int,
        hasPendingAttention: Bool,
        isActiveTab: Bool
    ) -> TabActivityStatus? {
        if state == .running { return .running }
        if hasPendingAttention { return .needsAttention }
        if !isActiveTab && unread > 0 { return .unread }
        return nil
    }
}
