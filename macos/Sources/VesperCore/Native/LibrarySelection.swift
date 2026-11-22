import Foundation

/// The Library grid's selection: click, ⌘-click to toggle, ⇧-click to extend from the anchor, and
/// arrow keys that move by one tile or by a row of `columns`. Pure so it can be tested.
public struct LibrarySelection: Equatable, Sendable {
    public enum Modifier: Sendable { case none, toggle, extend }

    public private(set) var selected: Set<String> = []
    /// The tile the keyboard acts on (Space, Return); always selected when set.
    public private(set) var focused: String?
    public private(set) var anchor: String?

    public init() {}

    public mutating func click(_ id: String, in ids: [String], modifier: Modifier = .none) {
        switch modifier {
        case .toggle:
            if selected.contains(id) {
                selected.remove(id)
                focused = selected.isEmpty ? nil : (focused == id ? ids.first(where: selected.contains) : focused)
                return
            }
            selected.insert(id)
            anchor = id
        case .extend:
            if let anchor, let from = ids.firstIndex(of: anchor), let to = ids.firstIndex(of: id) {
                selected = Set(ids[min(from, to)...max(from, to)])
            } else {
                selected = [id]
                anchor = id
            }
        case .none:
            selected = [id]
            anchor = id
        }
        focused = id
    }

    /// Arrow keys: ←/→ move by one, ↑/↓ by a row. With `extend` (⇧) the range from the anchor grows.
    /// Nothing focused yet starts at the first tile.
    public mutating func move(by offset: Int, in ids: [String], extend: Bool = false) {
        guard !ids.isEmpty else { return }
        guard let focused, let at = ids.firstIndex(of: focused) else {
            click(ids[0], in: ids)
            return
        }
        let next = ids[min(max(at + offset, 0), ids.count - 1)]
        click(next, in: ids, modifier: extend ? .extend : .none)
    }

    public mutating func selectAll(_ ids: [String]) {
        selected = Set(ids)
        if !(focused.map(ids.contains) ?? false) { focused = ids.first }
        anchor = focused
    }

    public mutating func clear() {
        selected = []
        focused = nil
        anchor = nil
    }

    /// Drops tiles that are no longer listed (removed, or another tab).
    public mutating func prune(to ids: [String]) {
        let present = Set(ids)
        selected.formIntersection(present)
        if let f = focused, !present.contains(f) { focused = ids.first(where: selected.contains) }
        if let a = anchor, !present.contains(a) { anchor = focused }
    }

    /// What a context-menu action on `id` applies to: the whole selection when `id` is part of a
    /// multi-selection, else just `id`. In display order.
    public func targets(for id: String, in ids: [String]) -> [String] {
        selected.contains(id) && selected.count > 1 ? ids.filter(selected.contains) : [id]
    }

    /// The selection in display order (Quick Look, bulk actions).
    public func ordered(_ ids: [String]) -> [String] { ids.filter(selected.contains) }
}
