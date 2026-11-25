import Foundation

/// Pure logic for the native SVG mockup editor (`/artifacts/:id?edit=1`): bounded undo/redo history
/// with edit coalescing. Validation is `MockupSVGProfile`; edits are `MockupSVGEditing`.
public enum MockupEditorLogic {

    /// Bounded undo/redo stack for SVG source strings with optional coalescing keys.
    public struct SourceHistory: Sendable, Equatable {
        public static let maxEntries = 100

        public private(set) var current: String
        private var past: [String] = []
        private var future: [String] = []
        private var lastKey: String?

        public init(initial: String) {
            self.current = initial
        }

        public var canUndo: Bool { !past.isEmpty }
        public var canRedo: Bool { !future.isEmpty }

        public mutating func commit(_ next: String, key: String? = nil) {
            guard next != current else { return }
            if !(key != nil && key == lastKey) {
                past.append(current)
                if past.count > Self.maxEntries { past.removeFirst() }
            }
            lastKey = key
            future.removeAll()
            current = next
        }

        public mutating func undo() -> String? {
            guard let prev = past.popLast() else { return nil }
            future.append(current)
            lastKey = nil
            current = prev
            return current
        }

        public mutating func redo() -> String? {
            guard let next = future.popLast() else { return nil }
            past.append(current)
            lastKey = nil
            current = next
            return current
        }

        public mutating func breakCoalesce() {
            lastKey = nil
        }
    }
}
