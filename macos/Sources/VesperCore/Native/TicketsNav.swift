import Foundation

/// Sidebar `NavModel` and toolbar/command builders for Tickets list (`/tickets`), Board
/// (`/tickets?layout=board`), and Ticket detail (`/tickets/:key`), matching the web models
/// (`tickets.ts`, `board.ts`, `ticket.ts`, `saved-views.ts`, `tickets-toolbar.ts`) without AppKit.
public enum TicketsNav {
    public static let listNavId = "tickets"
    public static let boardNavId = "board"
    public static let detailNavId = "ticket"

    // Shared Work header ids (kept aligned with WorkNav)
    public static let newTicketAction = WorkNav.newTicketAction
    public static let spaceFilter = WorkNav.spaceFilter
    public static let agentFilter = WorkNav.agentFilter
    public static let viewPicker = WorkNav.viewPicker
    public static let searchId = WorkNav.searchId

    // Tickets list section/row/action ids
    public static let openEpicsAction = "tickets.open-epics"
    public static let openEpicDetailAction = "epic.open-detail"
    public static let boardAllEpicsId = "all-epics"

    // Saved views ids
    public static let savedViewsSection = "saved-views"
    public static let svSave = "sv.save"
    public static let svRename = "sv.rename"
    public static let svSaveAs = "sv.save-as"
    public static let svCopyLink = "sv.copy-link"
    public static let svDelete = "sv.delete"

    // Toolbar ids
    public static let tbSpace = "tickets.space"
    public static let tbLayout = "tickets.layout"
    public static let tbAction = "tickets.action"
    public static let tlStartReady = "list.start-ready"
    public static let tlGroup = "list.group"
    public static let tlDensity = "list.density"
    public static let tbCanceled = "board.canceled"
    public static let tbBlocked = "board.blocked"

    public static func queueItemId(_ queue: TicketsLogic.Queue) -> String { "queue:\(queue.rawValue)" }
    public static func epicItemId(_ id: String) -> String { "epic:\(id)" }
    public static func savedViewItemId(_ id: String) -> String { "sv:\(id)" }

    public struct ListInput: Sendable {
        public var project: String?
        public var projects: [(key: String, name: String, archived: Bool)] = []
        public var agents: [(handle: String, name: String)] = []
        public var agent: String = ""
        public var search: String = ""
        public var counts = TicketsLogic.QueueCounts()
        public var queue: TicketsLogic.Queue? = .all
        public var epics: [TicketsLogic.SidebarEpic] = []
        public var epic: String?
        public var views: [API.SavedView] = []
        public var viewId: String?

        public init() {}
    }

    public struct BoardInput: Sendable {
        public var project: String?
        public var projects: [(key: String, name: String, archived: Bool)] = []
        public var agents: [(handle: String, name: String)] = []
        public var agent: String = ""
        public var epics: [(id: String, name: String)]?
        public var epic: String?

        public init() {}
    }

    public struct DetailInput: Sendable {
        public var project: String?
        public var siblings: [API.TicketSummary] = []
        public var ticketKey: String

        public init(project: String? = nil, siblings: [API.TicketSummary] = [], ticketKey: String) {
            self.project = project
            self.siblings = siblings
            self.ticketKey = ticketKey
        }
    }

    public static func savedViewMenu() -> [MenuItem] {
        [
            MenuItem(id: svRename, label: "Rename…", icon: "edit"),
            MenuItem(id: svSaveAs, label: "Save as new view…", icon: "bookmark"),
            MenuItem(id: svCopyLink, label: "Copy link", icon: "link"),
            MenuItem(id: "sv.sep", separator: true),
            MenuItem(id: svDelete, label: "Delete view", icon: "trash", destructive: true),
        ]
    }

    /// Title menu when viewing an open saved view.
    public static func savedViewTitleMenu() -> [MenuItem] {
        savedViewMenu()
    }

    public static func spaceMenu(
        projects: [(key: String, name: String, archived: Bool)],
        currentKey: String?,
        currentName: String?,
        allowAll: Bool
    ) -> [MenuItem] {
        var items: [MenuItem] = []
        let cur = currentKey ?? ""
        if allowAll {
            items.append(MenuItem(id: "space:", label: "All spaces", icon: "folder", checked: cur.isEmpty))
            items.append(MenuItem(id: "sep-all", separator: true))
        }
        for project in projects where !project.archived {
            items.append(MenuItem(id: "space:\(project.key)", label: project.name, checked: cur == project.key))
        }
        items.append(MenuItem(id: "sep-open", separator: true))
        items.append(MenuItem(
            id: "space-open",
            label: cur.isEmpty ? "New space" : "Open \(currentName ?? cur)",
            icon: cur.isEmpty ? "plus" : "gear"
        ))
        return items
    }

    public static func savedViewsSection(views: [API.SavedView], project: String?) -> NavSection {
        NavSection(
            id: savedViewsSection,
            title: "Saved views",
            items: views.map { view in
                NavItem(
                    id: savedViewItemId(view.id),
                    title: view.name,
                    icon: "bookmark",
                    href: TicketsLogic.savedViewHref(id: view.id, query: view.query, project: project),
                    contextMenu: savedViewMenu()
                )
            },
            actions: [NavAction(id: svSave, label: "Save view…", icon: "plus")],
            emptyText: "No saved views"
        )
    }

    private static func workFilters(
        project: String?,
        projects: [(key: String, name: String, archived: Bool)],
        agents: [(handle: String, name: String)],
        agent: String,
        allowAllProjects: Bool
    ) -> [NavFilterMenu] {
        var spaceOptions: [NavFilterOption] = []
        if allowAllProjects {
            spaceOptions.append(NavFilterOption(value: "", label: "All spaces", checked: (project ?? "").isEmpty))
        }
        spaceOptions += projects
            .filter { !$0.archived }
            .map { NavFilterOption(value: $0.key, label: $0.name, checked: project == $0.key) }

        let personaOptions = [NavFilterOption(value: "", label: "All personas", checked: agent.isEmpty)]
            + agents.map { NavFilterOption(value: $0.handle, label: $0.name, checked: agent == $0.handle) }

        return [
            NavFilterMenu(id: spaceFilter, label: "Space", icon: "briefcase", options: spaceOptions),
            NavFilterMenu(id: agentFilter, label: "Persona", icon: "agents", options: personaOptions),
        ]
    }

    private static func workPicker(ticketsCount: Int?) -> NavPicker {
        let tasksLabel = (ticketsCount ?? 0) > 0 ? "Tasks \(ticketsCount!)" : "Tasks"
        return NavPicker(id: viewPicker, value: "tickets", options: [
            NavPickerOption(value: "activity", label: "Runs"),
            NavPickerOption(value: "tickets", label: tasksLabel),
        ])
    }

    public static func listModel(_ input: ListInput) -> NavModel {
        var sections: [NavSection] = [
            NavSection(
                id: "queues",
                title: "Queues",
                items: TicketsLogic.Queue.allCases.map { queue in
                    let count = input.counts[queue]
                    return NavItem(
                        id: queueItemId(queue),
                        title: queue.title,
                        badge: count > 0 ? NavBadge(text: "\(count)", tone: queue.badgeTone) : nil,
                        status: queue.statusTone
                    )
                }
            ),
        ]

        if !input.epics.isEmpty {
            sections.append(NavSection(
                id: "by-epic",
                title: "By epic",
                items: input.epics.map { epic in
                    NavItem(
                        id: epicItemId(epic.id),
                        title: epic.name,
                        trailing: "\(epic.done)/\(epic.total)",
                        contextMenu: [
                            MenuItem(id: openEpicDetailAction, label: "Open epic details", icon: "epics"),
                        ]
                    )
                },
                actions: [NavAction(id: openEpicsAction, label: "All epics", icon: "epics")],
                badge: NavBadge(text: "\(input.epics.count)")
            ))
        }

        sections.append(savedViewsSection(views: input.views, project: input.project))

        let selected: String? = if let viewId = input.viewId, !viewId.isEmpty {
            savedViewItemId(viewId)
        } else if let epic = input.epic, !epic.isEmpty {
            epicItemId(epic)
        } else if let queue = input.queue {
            queueItemId(queue)
        } else {
            nil
        }

        return NavModel(
            id: listNavId,
            title: "Work",
            actions: [],
            picker: workPicker(ticketsCount: input.counts.all),
            filters: workFilters(
                project: input.project,
                projects: input.projects,
                agents: input.agents,
                agent: input.agent,
                allowAllProjects: true
            ),
            search: NavSearch(id: searchId, placeholder: "Filter tasks… epic: persona:", value: input.search),
            sections: sections,
            selectedId: selected
        )
    }

    public static func boardModel(_ input: BoardInput) -> NavModel {
        var sections: [NavSection] = []
        if let epics = input.epics {
            let items = [NavItem(id: boardAllEpicsId, title: "All epics")]
                + epics.map { NavItem(id: epicItemId($0.id), title: $0.name) }
            sections.append(NavSection(id: "by-epic", title: "By epic", items: items))
        }
        let selected: String? = if let epic = input.epic, !epic.isEmpty {
            epicItemId(epic)
        } else if input.epics != nil {
            boardAllEpicsId
        } else {
            nil
        }

        return NavModel(
            id: boardNavId,
            title: "Work",
            actions: [],
            picker: workPicker(ticketsCount: nil),
            filters: workFilters(
                project: input.project,
                projects: input.projects,
                agents: input.agents,
                agent: input.agent,
                allowAllProjects: false
            ),
            sections: sections,
            selectedId: selected
        )
    }

    public static func detailModel(_ input: DetailInput) -> NavModel {
        let items = input.siblings.map { sibling in
            NavItem(
                id: sibling.key,
                title: sibling.title,
                subtitle: "\(sibling.key) · \(TicketsLogic.statusLabel(sibling.status))",
                status: TicketsLogic.statusTone(sibling.status),
                href: "/tickets/\(WorkLogic.encode(sibling.key))"
            )
        }
        return NavModel(
            id: detailNavId,
            title: "Work",
            actions: [NavAction(id: newTicketAction, label: "New ticket", icon: "plus", accent: true)],
            picker: workPicker(ticketsCount: nil),
            filters: [],
            sections: [NavSection(id: "tickets", items: items)],
            selectedId: input.ticketKey
        )
    }

    // MARK: Toolbar Builders

    public static func listToolbarExtras(
        readyCount: Int,
        group: TicketsLogic.GroupBy,
        density: TicketsLogic.Density
    ) -> [ToolbarItem] {
        var items: [ToolbarItem] = []
        if readyCount > 0 {
            items.append(ToolbarItem(
                id: tlStartReady, label: "Start ready (\(readyCount))", icon: "play",
                kind: .button, showsLabel: true
            ))
        }
        items.append(ToolbarItem(
            id: tlGroup,
            label: "Group: \(group.label)",
            icon: "sliders",
            kind: .menu,
            menu: TicketsLogic.GroupBy.allCases.map {
                MenuItem(id: "group:\($0.rawValue)", label: $0.label, checked: $0 == group)
            },
            showsLabel: true
        ))
        items.append(ToolbarItem(
            id: tlDensity,
            label: "Density",
            icon: "sidebar",
            kind: .menu,
            menu: TicketsLogic.Density.allCases.map {
                MenuItem(id: "density:\($0.rawValue)", label: $0.label, checked: $0 == density)
            }
        ))
        return items
    }

    public static func boardToolbarExtras(showCanceled: Bool, blockedOnly: Bool) -> [ToolbarItem] {
        [
            ToolbarItem(id: tbCanceled, label: "Show canceled", icon: "x", kind: .toggle, on: showCanceled, showsLabel: true),
            ToolbarItem(id: tbBlocked, label: "Blocked only", icon: "alert", kind: .toggle, on: blockedOnly, showsLabel: true),
        ]
    }

    public static func ticketsToolbar(
        spaceName: String,
        spaceMenu: [MenuItem],
        layout: TicketsLogic.Layout,
        action: (label: String, primary: Bool)?,
        extra: [ToolbarItem] = []
    ) -> [ToolbarItem] {
        let layouts = layout == .epics ? TicketsLogic.Layout.allCases : TicketsLogic.primaryLayouts
        var items: [ToolbarItem] = [
            ToolbarItem(
                id: tbSpace, label: spaceName, icon: "folder", kind: .menu,
                menu: spaceMenu, showsLabel: true, placement: .leading
            ),
        ]
        items.append(contentsOf: extra)
        items.append(ToolbarItem(
            id: tbLayout,
            label: layout.label,
            icon: layout.icon,
            kind: .menu,
            menu: layouts.map {
                MenuItem(id: "layout:\($0.rawValue)", label: $0.label, icon: $0.icon, checked: $0 == layout)
            },
            showsLabel: true
        ))
        if let action {
            items.append(ToolbarItem(
                id: tbAction,
                label: action.label,
                icon: action.primary ? "plus" : "gear",
                kind: .button,
                accent: action.primary,
                showsLabel: true
            ))
        }
        return items
    }

    // MARK: Command Decoding

    public enum Action: Sendable, Equatable {
        case open(String, newTab: Bool)
        case project(String)
        case agent(String)
        case search(String)
        case selectQueue(TicketsLogic.Queue)
        case selectEpic(String?)
        case openEpicDetail(String)
        case openEpics
        case openSavedView(String, newTab: Bool)
        case saveSavedView
        case renameSavedView(String)
        case saveAsSavedView(String)
        case copySavedViewLink(String)
        case deleteSavedView(String)
        case switchLayout(TicketsLogic.Layout)
        case primaryAction
        case startReady
        case groupBy(TicketsLogic.GroupBy)
        case density(TicketsLogic.Density)
        case toggleShowCanceled
        case toggleBlockedOnly
        case openSpaceSettings(String?)
    }

    public static func action(
        for command: NativeCommand,
        navigatorId: String,
        project: String?
    ) -> Action? {
        switch command {
        case .toolbarAction(let itemId, let menuItemId):
            if itemId == tbSpace, let menuItemId {
                if menuItemId == "space-open" { return .openSpaceSettings(project) }
                if menuItemId.hasPrefix("space:") { return .project(String(menuItemId.dropFirst(6))) }
            }
            if itemId == tbLayout, let menuItemId, menuItemId.hasPrefix("layout:") {
                return TicketsLogic.Layout(rawValue: String(menuItemId.dropFirst(7))).map(Action.switchLayout)
            }
            if itemId == tbAction { return .primaryAction }
            if itemId == tlStartReady { return .startReady }
            if itemId == tlGroup, let menuItemId, menuItemId.hasPrefix("group:") {
                return TicketsLogic.GroupBy(rawValue: String(menuItemId.dropFirst(6))).map(Action.groupBy)
            }
            if itemId == tlDensity, let menuItemId, menuItemId.hasPrefix("density:") {
                return TicketsLogic.Density(rawValue: String(menuItemId.dropFirst(8))).map(Action.density)
            }
            if itemId == tbCanceled { return .toggleShowCanceled }
            if itemId == tbBlocked { return .toggleBlockedOnly }
            return nil

        case .navAction(navigatorId, newTicketAction, _, _):
            return .open(WorkLogic.newTicketHref(project: project), newTab: false)

        case .navFilter(navigatorId, spaceFilter, let value, _):
            return .project(value)

        case .navFilter(navigatorId, agentFilter, let value, _):
            return .agent(value)

        case .navPicker(navigatorId, viewPicker, let value):
            if value == "activity" {
                let path = (project ?? "").isEmpty ? "/work" : "/work?project=\(WorkLogic.encode(project!))"
                return .open(path, newTab: false)
            }
            return .open(WorkLogic.tasksHref(project: project), newTab: false)

        case .navSearch(navigatorId, searchId, let value):
            return .search(value)

        case .navAction(navigatorId, openEpicsAction, _, _):
            return .openEpics

        case .navAction(navigatorId, openEpicDetailAction, let itemId, _):
            if let itemId, itemId.hasPrefix("epic:") {
                return .openEpicDetail(String(itemId.dropFirst(5)))
            }
            return nil

        case .navAction(navigatorId, svSave, nil, _):
            return .saveSavedView

        case .navAction(navigatorId, let actionId, let itemId, let menuItemId):
            // Context menu actions on saved views may pass actionId == svRename etc., or menuItemId.
            let targetAction = (actionId.hasPrefix("sv.") ? actionId : nil) ?? menuItemId
            if let targetAction, let itemId, itemId.hasPrefix("sv:") {
                let svId = String(itemId.dropFirst(3))
                switch targetAction {
                case svRename: return .renameSavedView(svId)
                case svSaveAs: return .saveAsSavedView(svId)
                case svCopyLink: return .copySavedViewLink(svId)
                case svDelete: return .deleteSavedView(svId)
                default: break
                }
            }
            if let menuItemId, menuItemId == openEpicDetailAction, let itemId, itemId.hasPrefix("epic:") {
                return .openEpicDetail(String(itemId.dropFirst(5)))
            }
            return nil

        case .navActivate(navigatorId, let itemId, let newTab):
            if itemId == boardAllEpicsId { return .selectEpic(nil) }
            if itemId.hasPrefix("queue:") {
                return TicketsLogic.Queue(rawValue: String(itemId.dropFirst(6))).map(Action.selectQueue)
            }
            if itemId.hasPrefix("epic:") {
                return .selectEpic(String(itemId.dropFirst(5)))
            }
            if itemId.hasPrefix("sv:") {
                return .openSavedView(String(itemId.dropFirst(3)), newTab: newTab)
            }
            if navigatorId == detailNavId {
                return .open("/tickets/\(WorkLogic.encode(itemId))", newTab: newTab)
            }
            return nil

        default:
            return nil
        }
    }
}
