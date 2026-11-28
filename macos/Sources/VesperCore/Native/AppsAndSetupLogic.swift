import Foundation

/// Pure logic for `/apps` (Custom Apps Home), `/apps/docs|slides|designs` redirects,
/// `/` landing resolution, and `/setup` onboarding checks.
public enum AppsHomeLogic {
    public struct StarterSpec: Sendable, Equatable, Identifiable {
        public let template: API.NewCustomApp.Template
        public let label: String
        public let icon: String
        public let defaultIcon: String
        public let detail: String

        public var id: String { template.rawValue }
    }

    public static let icons: [String] = [
        "dashboard", "dollar", "board", "graph", "bolt", "compass",
        "briefcase", "server", "clock", "tickets", "gamepad", "dice",
    ]

    public static let reservedSlugs: Set<String> = ["new", "api", "slides", "designs", "docs"]

    public static let starters: [StarterSpec] = [
        StarterSpec(
            template: .blank,
            label: "Blank",
            icon: "code",
            defaultIcon: "dashboard",
            detail: "Clean React + TypeScript + SQLite canvas ready for custom views."
        ),
        StarterSpec(
            template: .tracker,
            label: "Tracker",
            icon: "tickets",
            defaultIcon: "tickets",
            detail: "Status views, quick entry, and SQLite persistence out of the box."
        ),
        StarterSpec(
            template: .ledger,
            label: "Ledger",
            icon: "dollar",
            defaultIcon: "dollar",
            detail: "Accounts, transactions, and category summaries in embedded SQLite."
        ),
    ]

    public static func resolveIcon(_ icon: String?) -> String {
        if let icon, icons.contains(icon) { return icon }
        return "dashboard"
    }

    public static func slugify(_ name: String) -> String {
        let lower = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let replaced = lower.replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
        let trimmed = replaced.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return String(trimmed.prefix(48)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    public static func validateSlug(_ slug: String) -> String? {
        let s = slug.trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.range(of: #"^[a-z0-9][a-z0-9-]{0,47}$"#, options: .regularExpression) != nil else {
            return "Use 1\u{2013}48 lowercase letters, digits, or hyphens starting with a letter or digit."
        }
        if reservedSlugs.contains(s) {
            return "\"\(s)\" is a reserved Vesper route."
        }
        return nil
    }

    public static func formatBytes(_ bytes: Int) -> String {
        ChatCodeReviewLogic.formatBytes(bytes)
    }

    public static func knowledgeRedirectPath(for path: String) -> String? {
        switch path {
        case "/apps/docs": return "/knowledge?kind=document"
        case "/apps/slides": return "/knowledge?kind=deck"
        case "/apps/designs": return "/knowledge?kind=design"
        default: return nil
        }
    }

    // MARK: - Sidebar NavModel

    public static let navId = "apps-home"
    public static let newAppAction = "new-app"
    public static let searchId = "apps-search"
    public static let appPrefix = "app:"
    public static let toolPrefix = "tool:"
    public static let starterPrefix = "starter:"
    public static let openNewTabMenu = "open-new-tab"
    public static let openStandaloneMenu = "open-standalone"
    public static let deleteAppMenu = "delete-app"

    public struct ToolEntry: Sendable, Equatable {
        public let href: String
        public let label: String
        public let icon: String

        public init(href: String, label: String, icon: String) {
            self.href = href; self.label = label; self.icon = icon
        }
    }

    public static func toolEntries(devWorkspaceEnabled: Bool) -> [ToolEntry] {
        var tools: [ToolEntry] = [
            ToolEntry(href: "/workflows", label: "Workflows", icon: "graph"),
            ToolEntry(href: "/scheduled", label: "Scheduled", icon: "clock"),
            ToolEntry(href: "/learn", label: "Learn", icon: "learn"),
            ToolEntry(href: "/reports", label: "Reports", icon: "dollar"),
            ToolEntry(href: "/http", label: "HTTP Client", icon: "plug"),
        ]
        if devWorkspaceEnabled {
            tools.append(ToolEntry(href: "/dev", label: "Dev workspace", icon: "terminal"))
        }
        return tools
    }

    public static func navModel(
        apps: [API.CustomAppSummary],
        search: String = "",
        devWorkspaceEnabled: Bool = false,
        loading: Bool = false
    ) -> NavModel {
        let trimmed = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let needle = trimmed.lowercased()

        let filteredApps = needle.isEmpty ? apps : apps.filter {
            $0.name.lowercased().contains(needle)
                || $0.slug.lowercased().contains(needle)
                || $0.description.lowercased().contains(needle)
        }
        let filteredTools = toolEntries(devWorkspaceEnabled: devWorkspaceEnabled).filter {
            needle.isEmpty || $0.label.lowercased().contains(needle)
        }
        let filteredStarters = starters.filter {
            needle.isEmpty || $0.label.lowercased().contains(needle) || $0.detail.lowercased().contains(needle)
        }

        let appItems = filteredApps.map { app in
            NavItem(
                id: "\(appPrefix)\(app.slug)",
                title: app.name,
                subtitle: app.description.isEmpty ? nil : app.description,
                icon: resolveIcon(app.icon),
                href: "/apps/\(app.slug)",
                contextMenu: [
                    MenuItem(id: openStandaloneMenu, label: "Open in Standalone Window", icon: "window"),
                    MenuItem(id: openNewTabMenu, label: "Open in New Tab", icon: "external"),
                    MenuItem(id: deleteAppMenu, label: "Delete\u{2026}", icon: "trash", destructive: true),
                ]
            )
        }
        let appEmptyText: String = {
            if loading && apps.isEmpty { return "Loading\u{2026}" }
            return trimmed.isEmpty ? "No custom apps yet." : "No custom apps match."
        }()

        var sections: [NavSection] = [
            NavSection(
                id: "your-apps",
                title: "Your apps",
                items: appItems,
                badge: appItems.isEmpty ? nil : NavBadge(text: "\(appItems.count)"),
                emptyText: appEmptyText
            ),
        ]

        if !filteredTools.isEmpty {
            sections.append(NavSection(
                id: "tools",
                title: "Tools",
                items: filteredTools.map { tool in
                    NavItem(
                        id: "\(toolPrefix)\(tool.href)",
                        title: tool.label,
                        icon: tool.icon,
                        href: tool.href,
                        contextMenu: [MenuItem(id: openNewTabMenu, label: "Open in New Tab", icon: "external")]
                    )
                }
            ))
        }

        if !filteredStarters.isEmpty {
            sections.append(NavSection(
                id: "starters",
                title: "Starter templates",
                items: filteredStarters.map { starter in
                    NavItem(id: "\(starterPrefix)\(starter.template.rawValue)", title: starter.label, icon: starter.icon)
                }
            ))
        }

        return NavModel(
            id: navId,
            title: "Apps",
            actions: [NavAction(id: newAppAction, label: "New app", icon: "plus", accent: true)],
            search: NavSearch(id: searchId, placeholder: "Filter apps\u{2026}", value: search),
            sections: sections
        )
    }

    public enum NavActionResult: Sendable, Equatable {
        case newApp(API.NewCustomApp.Template)
        case openPath(String, newTab: Bool)
        case openStandalone(slug: String)
        case deleteApp(slug: String)
        case search(String)
    }

    public static func navAction(for command: NativeCommand) -> NavActionResult? {
        switch command {
        case .navAction(navId, newAppAction, _, _):
            return .newApp(.blank)
        case .navAction(navId, openStandaloneMenu, let itemId?, _):
            guard itemId.hasPrefix(appPrefix) else { return nil }
            return .openStandalone(slug: String(itemId.dropFirst(appPrefix.count)))
        case .navAction(navId, openNewTabMenu, let itemId?, _):
            if itemId.hasPrefix(appPrefix) {
                return .openPath("/apps/\(itemId.dropFirst(appPrefix.count))", newTab: true)
            }
            if itemId.hasPrefix(toolPrefix) {
                return .openPath(String(itemId.dropFirst(toolPrefix.count)), newTab: true)
            }
            return nil
        case .navAction(navId, deleteAppMenu, let itemId?, _):
            guard itemId.hasPrefix(appPrefix) else { return nil }
            return .deleteApp(slug: String(itemId.dropFirst(appPrefix.count)))
        case .navSearch(navId, searchId, let value):
            return .search(value)
        case .navActivate(navId, let itemId, let newTab):
            if itemId.hasPrefix(appPrefix) {
                return .openPath("/apps/\(itemId.dropFirst(appPrefix.count))", newTab: newTab)
            }
            if itemId.hasPrefix(toolPrefix) {
                return .openPath(String(itemId.dropFirst(toolPrefix.count)), newTab: newTab)
            }
            if itemId.hasPrefix(starterPrefix) {
                let raw = String(itemId.dropFirst(starterPrefix.count))
                return .newApp(API.NewCustomApp.Template(rawValue: raw))
            }
            return nil
        default:
            return nil
        }
    }
}

public enum LandingLogic {
    public static func needsWizard(me: API.User?) -> Bool {
        OnboardingLogic.needsWizard(me: me)
    }

    public static func needsProfileSetup(name: String, email: String) -> Bool {
        let lowerEmail = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return name.trimmingCharacters(in: .whitespacesAndNewlines) == "Local user"
            || lowerEmail == "me@localhost"
            || lowerEmail == "me@localhost.com"
    }

    public static func mostUsedPersona(personas: [API.Persona], fallback: String?) -> String? {
        var best: API.Persona?
        var bestDate: Date = .distantPast
        for p in personas where p.chatCount >= 1 {
            let used = p.lastUsedAt.flatMap { APIDate.parse($0) } ?? .distantPast
            if best == nil
                || p.chatCount > best!.chatCount
                || (p.chatCount == best!.chatCount && used > bestDate) {
                best = p
                bestDate = used
            }
        }
        return best?.id ?? fallback
    }

    public static func landingPath(me: API.User?, personas: [API.Persona], defaultPersonaId: String?) -> String {
        if needsWizard(me: me) {
            return "/chat?new"
        }
        if let persona = mostUsedPersona(personas: personas, fallback: defaultPersonaId),
           let encoded = persona.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            return "/chat?new&persona=\(encoded)"
        }
        return "/chat?new"
    }
}
