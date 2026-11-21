import Foundation
import Observation
import VesperCore
import WebKit

/// What the window's find bar searches: the web view, or the native screen showing instead.
@MainActor
protocol FindTarget: AnyObject {
    /// Moves to the next (or previous) match of `query`; false when there is none.
    func find(_ query: String, backwards: Bool, caseSensitive: Bool) async -> Bool
    /// Removes every highlight.
    func clearFind()
}

extension WKWebView: FindTarget {
    func find(_ query: String, backwards: Bool, caseSensitive: Bool) async -> Bool {
        let config = WKFindConfiguration()
        config.backwards = backwards
        config.caseSensitive = caseSensitive
        config.wraps = true
        return (try? await find(query, configuration: config))?.matchFound ?? false
    }

    func clearFind() {
        Task { @MainActor [weak self] in _ = try? await self?.find("", configuration: WKFindConfiguration()) }
    }
}

/// Find for a native screen: the screen lists each row's searchable text in `texts`, then
/// highlights the rows that match and scrolls to `current`.
@MainActor
@Observable
final class NativeFindModel: FindTarget {
    /// Each row's searchable text, in display order. The screen keeps it current.
    var texts: [String] = []
    private(set) var query = ""
    private(set) var caseSensitive = false
    /// The row with the current match, to scroll to and mark; nil when nothing matches.
    private(set) var current: Int?

    func find(_ query: String, backwards: Bool, caseSensitive: Bool) async -> Bool {
        let changed = query != self.query || caseSensitive != self.caseSensitive
        self.query = query
        self.caseSensitive = caseSensitive
        // A new query starts at the current row, so typing keeps the match in view when it still fits.
        let from = changed ? current.map { $0 - 1 } : current
        current = FindLogic.nextMatch(in: texts, query: query, caseSensitive: caseSensitive, after: from, backwards: backwards)
        return current != nil
    }

    func clearFind() {
        query = ""
        current = nil
    }

    /// True when `text` contains the query (every match is marked, the current one more strongly).
    func matches(_ text: String) -> Bool {
        guard FindLogic.shouldSearch(query: query) else { return false }
        return text.range(of: query, options: caseSensitive ? [] : [.caseInsensitive, .diacriticInsensitive]) != nil
    }
}
