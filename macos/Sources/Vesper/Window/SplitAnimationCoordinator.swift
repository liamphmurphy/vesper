import AppKit

/// Tracks active programmatic split-view collapse/expand animations per `NSWindow` without
/// touching SwiftUI's `@Observable` graph.
///
/// Checking `isAnimating(window:)` from AppKit representables (`MarkdownTextView`,
/// `MarkdownRenderCoordinator`) avoids frame-0 SwiftUI body invalidations while allowing heavy
/// TextKit 2 reflows to defer until the ~220ms split slide settles, then run once cleanly.
@MainActor
final class SplitAnimationCoordinator {
    static let shared = SplitAnimationCoordinator()

    private struct WindowEntry {
        var depth: Int = 0
        var settleHandlers: [ObjectIdentifier: @MainActor () -> Void] = [:]
    }

    private var entries: [ObjectIdentifier: WindowEntry] = [:]

    /// True while any window currently has a split-view animation in flight (read by Perf HUD).
    var hasActiveAnimation: Bool {
        entries.values.contains { $0.depth > 0 }
    }

    func isAnimating(window: NSWindow?) -> Bool {
        guard let window else { return false }
        return (entries[ObjectIdentifier(window)]?.depth ?? 0) > 0
    }

    @discardableResult
    func beginAnimation(for window: NSWindow?) -> ObjectIdentifier? {
        guard let window else { return nil }
        let key = ObjectIdentifier(window)
        var entry = entries[key] ?? WindowEntry()
        entry.depth += 1
        entries[key] = entry
        return key
    }

    func endAnimation(for window: NSWindow?) {
        guard let window else { return }
        endAnimation(windowId: ObjectIdentifier(window))
    }

    func endAnimation(windowId: ObjectIdentifier?) {
        guard let windowId, var entry = entries[windowId] else { return }
        entry.depth -= 1
        if entry.depth > 0 {
            entries[windowId] = entry
            return
        }
        entries.removeValue(forKey: windowId)
        for handler in entry.settleHandlers.values {
            handler()
        }
    }

    /// Registers a one-shot settle callback coalesced per `owner` for the active animation on `window`.
    func registerSettleHandler(
        for window: NSWindow?,
        owner: AnyObject,
        handler: @escaping @MainActor () -> Void
    ) {
        guard let window else { return }
        let key = ObjectIdentifier(window)
        guard var entry = entries[key], entry.depth > 0 else { return }
        entry.settleHandlers[ObjectIdentifier(owner)] = handler
        entries[key] = entry
    }

    func clear(for window: NSWindow?) {
        guard let window else { return }
        entries.removeValue(forKey: ObjectIdentifier(window))
    }
}
