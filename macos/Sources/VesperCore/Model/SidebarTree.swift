import Foundation

/// One group in the sidebar's Apps menu.
public struct AppsMenuSection: Equatable, Sendable {
    public let title: String
    public let apps: [ShellApp]

    public init(title: String, apps: [ShellApp]) { self.title = title; self.apps = apps }
}

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

    /// The Apps menu's groups, in order: the person's own apps (ids `app:…`), then the tools (`tool:…`).
    /// The page sends them as one flat list; an empty group is left out rather than shown as a bare header.
    public static func appsMenuSections(_ apps: [ShellApp]) -> [AppsMenuSection] {
        let yours = apps.filter { $0.id.hasPrefix("app:") }
        let tools = apps.filter { !$0.id.hasPrefix("app:") }
        var sections: [AppsMenuSection] = []
        if !yours.isEmpty { sections.append(AppsMenuSection(title: "Your apps", apps: yours)) }
        if !tools.isEmpty { sections.append(AppsMenuSection(title: "Tools", apps: tools)) }
        return sections
    }

    public enum AreaClickOutcome: Equatable, Sendable {
        case navigate(String)
        case openInNewTab(String)
        case showAppsMenu
    }

    /// What clicking a left-sidebar area button does: ⌘-click always opens in a new tab;
    /// clicking Apps opens its menu when custom apps or tools exist, else navigates to `/apps`.
    public static func areaClick(
        href: String,
        isAppsButton: Bool = false,
        hasApps: Bool = false,
        commandClick: Bool
    ) -> AreaClickOutcome {
        if commandClick { return .openInNewTab(href) }
        if isAppsButton && hasApps { return .showAppsMenu }
        return .navigate(href)
    }
}
