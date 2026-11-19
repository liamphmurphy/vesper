import Foundation

/// Pure visibility and tab-routing helpers for the native macOS inspector split item.
public enum InspectorLogic {
    private static let railDockTabPrefix = "dock.tab:"

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

    /// True when `tabId` exists in `model` and is rendered inside the native inspector (`native` or `companion`).
    public static func isNativeTab(_ tabId: String, in model: InspectorModel?) -> Bool {
        guard let tab = model?.tabs.first(where: { $0.id == tabId }) else { return false }
        return tab.kind != .web
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
