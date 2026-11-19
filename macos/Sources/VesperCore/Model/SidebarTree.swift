import Foundation

/// Pure visibility and ancestor lookup for `NavModel` trees, shared by the native sidebar's
/// selection binding, scroll-to-selection target, and stale-override cleanup.
public enum SidebarTree {
    /// True when `id` exists in `nav` and both its containing section and every ancestor folder
    /// are currently expanded (taking local overrides into account).
    public static func isVisible(
        _ id: String,
        in nav: NavModel,
        expandedOverrides: [String: Bool] = [:],
        collapsedOverrides: [String: Bool] = [:]
    ) -> Bool {
        func walk(_ items: [NavItem]) -> Bool {
            for item in items {
                if item.id == id { return true }
                if let children = item.children, !children.isEmpty,
                   expandedOverrides[item.id] ?? item.expanded ?? false,
                   walk(children) {
                    return true
                }
            }
            return false
        }
        for section in nav.sections {
            if collapsedOverrides[section.id] ?? section.collapsed ?? false { continue }
            if walk(section.items) { return true }
        }
        return false
    }

    /// The section id and ancestor folder item ids that wrap `id`, or `nil` when `id` isn't in `nav`.
    public static func path(to id: String, in nav: NavModel) -> (sectionId: String, ancestors: [String])? {
        func walk(_ items: [NavItem], trail: [String]) -> [String]? {
            for item in items {
                if item.id == id { return trail }
                if let children = item.children, !children.isEmpty,
                   let found = walk(children, trail: trail + [item.id]) {
                    return found
                }
            }
            return nil
        }
        for section in nav.sections {
            if let ancestors = walk(section.items, trail: []) {
                return (section.id, ancestors)
            }
        }
        return nil
    }
}
