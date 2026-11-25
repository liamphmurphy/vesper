import Foundation

/// Per-tab browser-style navigation history for native Vesper tabs.
public struct NavigationHistory: Sendable, Equatable {
    private var entries: [String]
    private var index: Int
    private let maxEntries: Int

    public init(initial path: String, maxEntries: Int = 100) {
        self.maxEntries = max(1, maxEntries)
        self.entries = [Self.normalize(path)]
        self.index = 0
    }

    public var current: String { entries[index] }
    public var canGoBack: Bool { index > 0 }
    public var canGoForward: Bool { index + 1 < entries.count }
    public var count: Int { entries.count }

    /// Records a navigation to `path`.
    /// - Parameter replace: Overwrites the current entry instead of pushing, used for automatic
    ///   redirects so Back does not return to the redirecting route.
    /// - Returns: `true` if the current entry changed.
    @discardableResult
    public mutating func navigate(to path: String, replace: Bool = false) -> Bool {
        let normalized = Self.normalize(path)
        if normalized == entries[index] { return false }
        if replace {
            if index > 0 && entries[index - 1] == normalized {
                entries.remove(at: index)
                index -= 1
            } else {
                entries[index] = normalized
            }
            return true
        }
        if index + 1 < entries.count {
            entries.removeSubrange((index + 1)...)
        }
        entries.append(normalized)
        index += 1
        if entries.count > maxEntries {
            let overflow = entries.count - maxEntries
            entries.removeFirst(overflow)
            index = max(0, index - overflow)
        }
        return true
    }

    /// Moves back one entry and returns its path, or `nil` when already at the start.
    public mutating func goBack() -> String? {
        guard canGoBack else { return nil }
        index -= 1
        return entries[index]
    }

    /// Moves forward one entry and returns its path, or `nil` when already at the end.
    public mutating func goForward() -> String? {
        guard canGoForward else { return nil }
        index += 1
        return entries[index]
    }

    private static func normalize(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "/" : trimmed
    }
}
