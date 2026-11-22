import Foundation

/// Pure visibility and tab-routing helpers for the native macOS inspector split item.
public enum InspectorLogic {
    private static let railDockTabPrefix = "dock.tab:"
    public static let defaultCompanionModelId = "companion"
    public static let defaultCompanionTabId = "chat"

    /// Default companion inspector (`WorkChat` tab) shown on native screens that don't publish
    /// a custom `InspectorModel` of their own.
    public static func defaultCompanion(open: Bool, path: String?) -> InspectorModel {
        InspectorModel(
            id: defaultCompanionModelId,
            open: open,
            activeTabId: defaultCompanionTabId,
            tabs: [InspectorTab(id: defaultCompanionTabId, label: "Chat", icon: "msg", kind: .companion)],
            companion: CompanionContext(path: path)
        )
    }

    /// Resolves the inspector shown for a tab: a native screen uses its own `InspectorModel` when
    /// it publishes one, else the native default companion; web screens keep `pageInspector`.
    public static func effectiveInspector(
        nativeActive: Bool,
        nativeInspector: InspectorModel?,
        pageInspector: InspectorModel?,
        defaultCompanionOpen: Bool,
        path: String?
    ) -> InspectorModel? {
        if nativeActive {
            return nativeInspector ?? defaultCompanion(open: defaultCompanionOpen, path: path)
        }
        return pageInspector
    }

    /// The active tab in `model`, falling back to its first tab when `activeTabId` isn't present.
    public static func activeTab(in model: InspectorModel?) -> InspectorTab? {
        guard let model else { return nil }
        return model.tabs.first { $0.id == model.activeTabId } ?? model.tabs.first
    }

    /// True when the window's native inspector split pane should be expanded.
    public static func shouldShowNativeInspector(model: InspectorModel?, poppedOut: Bool = false) -> Bool {
        guard !poppedOut, let model, model.open, let tab = activeTab(in: model) else { return false }
        return tab.kind != .web
    }

    /// True when toggling the inspector (toolbar button, menu, `⌘\`, or rail button) should
    /// animate the native `NSSplitViewItem` directly rather than delegating to the web dock.
    public static func handlesToggleNatively(model: InspectorModel?, poppedOut: Bool = false) -> Bool {
        guard !poppedOut, let tab = activeTab(in: model) else { return false }
        return tab.kind != .web
    }

    /// True when `tabId` exists in `model` and is rendered inside the native inspector (`native`, `companion`, or `panel`).
    public static func isNativeTab(_ tabId: String, in model: InspectorModel?) -> Bool {
        guard let tab = model?.tabs.first(where: { $0.id == tabId }) else { return false }
        return tab.kind != .web
    }

    public struct InspectorThickness: Equatable, Sendable {
        public let min: Double
        public let max: Double
        public let preferred: Double

        public init(min: Double, max: Double, preferred: Double) {
            self.min = min; self.max = max; self.preferred = preferred
        }
    }

    public static func thickness(for width: InspectorWidth?) -> InspectorThickness {
        switch width ?? .regular {
        case .regular: InspectorThickness(min: 280, max: 640, preferred: 360)
        case .wide:    InspectorThickness(min: 360, max: 960, preferred: 540)
        case .max:     InspectorThickness(min: 420, max: 1120, preferred: 760)
        }
    }

    public static func popoutSize(for width: InspectorWidth?) -> (width: Double, height: Double) {
        switch width ?? .regular {
        case .regular: (380, 680)
        case .wide:    (560, 740)
        case .max:     (740, 780)
        }
    }

    /// Computes a desired inspector width clamped to `[spec.min, spec.max]` while preserving `minContentWidth` for the main pane.
    public static func desiredWidth(for width: InspectorWidth?, availableWidth: Double, minContentWidth: Double = 380) -> Double {
        let spec = thickness(for: width)
        let maxBySpace = Swift.max(spec.min, availableWidth - minContentWidth)
        return Swift.min(spec.preferred, Swift.min(spec.max, maxBySpace))
    }

    /// The `NSSplitView` divider index separating main content from the trailing inspector.
    public static func inspectorDividerIndex(hasSidebar: Bool) -> Int {
        hasSidebar ? 1 : 0
    }

    /// Extracts the dock tab id from a `dock.tab:<id>` rail button identifier.
    public static func railDockTabId(from railItemId: String) -> String? {
        guard railItemId.hasPrefix(railDockTabPrefix) else { return nil }
        let suffix = String(railItemId.dropFirst(railDockTabPrefix.count))
        return suffix.isEmpty ? nil : suffix
    }
}
