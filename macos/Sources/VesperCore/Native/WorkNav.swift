import Foundation

/// Work's Runs list in the sidebar, as the native screen publishes it: the Work header (Space and
/// Persona filters, Runs/Tasks switcher, New ticket, filter box), the Overview row, the View menu
/// and the runs. The Swift port of web/lib/native-shell/models/work.ts `workHeader` and
/// models/runs.ts `buildWorkActivityNavModel` (keep the ids in step: the sidebar sends them back).
public enum WorkNav {
    public static let id = "work-activity"
    public static let newTicketAction = "new-ticket"
    public static let spaceFilter = "filter-space"
    public static let agentFilter = "filter-agent"
    public static let viewPicker = "work-view"
    public static let searchId = "work-search"
    public static let viewFilter = "view"
    public static let overviewItem = "work:overview"
    public static let statusItem = "status"
    public static let loadMoreItem = "load-more"
    public static let retryItem = "retry"

    public static func runItemId(_ id: String) -> String { "run:\(id)" }
    public static func needsItemId(_ id: String) -> String { "needs:\(id)" }

    public struct RunRow: Sendable, Equatable {
        public var id: String
        public var title: String
        public var avatar: Avatar?
        public var trailing: String
        public var dot: WorkLogic.Dot

        public init(id: String, title: String, avatar: Avatar?, trailing: String, dot: WorkLogic.Dot) {
            self.id = id; self.title = title; self.avatar = avatar; self.trailing = trailing; self.dot = dot
        }
    }

    public struct NeedsRow: Sendable, Equatable {
        public var id: String
        public var title: String
        public var trailing: String

        public init(id: String, title: String, trailing: String) { self.id = id; self.title = title; self.trailing = trailing }
    }

    public struct Group: Sendable, Equatable {
        public var label: String
        public var runs: [RunRow]

        public init(label: String, runs: [RunRow]) { self.label = label; self.runs = runs }
    }

    public struct Input: Sendable {
        public var project: String?
        public var projects: [(key: String, name: String, archived: Bool)] = []
        public var agents: [(handle: String, name: String)] = []
        /// Selected persona handle ("" for all).
        public var agent: String = ""
        /// The Runs tab's count: needs plus running and queued runs.
        public var activityCount: Int = 0
        public var search: String = ""
        public var filter: WorkLogic.ActivityFilter = .all
        public var counts = WorkLogic.ViewCounts()
        public var needs: [NeedsRow] = []
        public var groups: [Group] = []
        public var loading = false
        public var error: String?
        public var hasMore = false
        public var loadingMore = false
        public var statusLine: (text: String, href: String)?

        public init() {}
    }

    /// A run's agent as its persona looks in the sidebar (web work-persona.ts `personaNavAvatar`):
    /// the persona's name, colour and picture, else the agent's identity hue (`hueColor`, a literal
    /// colour) and initials. Pictures resolve against the server, as the sidebar loads them.
    public static func avatar(for agent: API.AgentRef, personas: [API.Persona], base: URL?,
                              hueColor: (String) -> String?) -> Avatar {
        let persona = WorkPersona.match(personas, id: agent.id, handle: agent.handle, name: agent.name)
        let name = persona.map(\.name).flatMap { $0.isEmpty ? nil : $0 } ?? agent.name
        let color = persona.map(\.color).flatMap { $0.isEmpty ? nil : $0 } ?? hueColor(WorkPersona.hue(agent.colorIndex))
        let picture = persona?.avatarUrl.flatMap { $0.isEmpty ? nil : URL(string: $0, relativeTo: base)?.absoluteURL.absoluteString }
        let literal = color.flatMap { c in ["#", "rgb", "hsl"].contains { c.lowercased().hasPrefix($0) } ? c : nil }
        return Avatar(initials: initials(name), color: literal, imageUrl: picture)
    }

    /// "Ada Lovelace" → "AL", "Assistant" → "A" (web chats-model.ts `initials`).
    public static func initials(_ name: String) -> String {
        let words = name.split(whereSeparator: \.isWhitespace)
        let letters = words.count > 1 ? [words[0], words[words.count - 1]] : words
        let out = letters.compactMap { $0.first.map { String($0).uppercased() } }.joined()
        return out.isEmpty ? "?" : out
    }

    private static let dotTones: [WorkLogic.Dot: Tone] = [.human: .human, .running: .done, .failed: .blocked, .queued: .neutral]

    public static func model(_ input: Input) -> NavModel {
        let spaces = [NavFilterOption(value: "", label: "All spaces", checked: (input.project ?? "").isEmpty)]
            + input.projects.filter { !$0.archived }.map { NavFilterOption(value: $0.key, label: $0.name, checked: input.project == $0.key) }
        let personas = [NavFilterOption(value: "", label: "All personas", checked: input.agent.isEmpty)]
            + input.agents.map { NavFilterOption(value: $0.handle, label: $0.name, checked: input.agent == $0.handle) }
        let view = WorkLogic.ActivityFilter.allCases.map {
            NavFilterOption(value: $0.rawValue, label: "\($0.label) (\(input.counts[$0]))", checked: input.filter == $0)
        }
        let overview = NavItem(id: overviewItem, title: "Overview", icon: "activity",
                               badge: input.counts.needsYou > 0 ? NavBadge(text: "\(input.counts.needsYou)", tone: .human) : nil)
        var sections = [NavSection(id: "overview", items: [overview])] + body(input)
        if let status = input.statusLine, !status.text.isEmpty {
            sections.append(NavSection(id: "status", items: [NavItem(id: statusItem, title: status.text, icon: "activity", href: status.href)]))
        }
        return NavModel(
            id: id,
            title: "Work",
            actions: [NavAction(id: newTicketAction, label: "New ticket", icon: "plus", accent: true)],
            picker: NavPicker(id: viewPicker, value: "activity", options: [
                NavPickerOption(value: "activity", label: input.activityCount > 0 ? "Runs \(input.activityCount)" : "Runs"),
                NavPickerOption(value: "tickets", label: "Tasks"),
            ]),
            filters: [
                NavFilterMenu(id: spaceFilter, label: "Space", icon: "briefcase", options: spaces),
                NavFilterMenu(id: agentFilter, label: "Persona", icon: "agents", options: personas),
                NavFilterMenu(id: viewFilter, label: "View", icon: "activity", options: view),
            ],
            search: NavSearch(id: searchId, placeholder: "Filter runs…", value: input.search),
            sections: sections,
            selectedId: overviewItem
        )
    }

    /// The list under Overview (web models/runs.ts `bodySections`): Needs you items with no run row
    /// come after the groups (as "Waiting") while an Active group shows, else first.
    static func body(_ input: Input) -> [NavSection] {
        let hasActive = input.groups.contains { $0.label == "Active" }
        let needs = input.needs.isEmpty ? [] : [NavSection(
            id: "needs-you", title: hasActive ? "Waiting" : "Needs you", items: input.needs.map {
                NavItem(id: needsItemId($0.id), title: $0.title, icon: "inbox", status: .human, trailing: $0.trailing)
            }, badge: NavBadge(text: "\(input.needs.count)"))]
        if let error = input.error {
            return needs + [NavSection(id: "error", items: [
                NavItem(id: retryItem, title: "Couldn\u{2019}t load runs. \(error)", subtitle: "Retry", icon: "refresh"),
            ])]
        }
        if input.loading { return needs + [NavSection(id: "loading", items: [], emptyText: "Loading")] }
        let groups = input.groups.map { group in
            NavSection(id: "runs-\(group.label)", title: group.label, items: group.runs.map { run in
                NavItem(id: runItemId(run.id), title: run.title, avatar: run.avatar, status: dotTones[run.dot], trailing: run.trailing)
            }, badge: NavBadge(text: "\(group.runs.count)"))
        }
        if groups.isEmpty && needs.isEmpty {
            return [NavSection(id: "empty", items: [], emptyText: input.search.isEmpty ? "No runs in this view." : "No runs match.")]
        }
        var out = hasActive ? groups + needs : needs + groups
        if input.hasMore && !input.loading {
            out.append(NavSection(id: "more", items: [
                NavItem(id: loadMoreItem, title: "Load older runs", icon: "history", disabled: input.loadingMore),
            ]))
        }
        return out
    }

    /// What a sidebar command asks the screen to do.
    public enum Action: Sendable, Equatable {
        case open(String, newTab: Bool)
        case project(String)
        case agent(String)
        case search(String)
        case filter(WorkLogic.ActivityFilter)
        case overview
        case loadMore
        case retry
        case openRun(String, newTab: Bool)
        case openNeeds(String, newTab: Bool)
    }

    /// Decodes a command from Work's navigator; nil for anything else.
    public static func action(for command: NativeCommand, project: String?) -> Action? {
        switch command {
        case .navAction(id, newTicketAction, _, _):
            return .open(WorkLogic.newTicketHref(project: project), newTab: false)
        case .navFilter(id, spaceFilter, let value, _):
            return .project(value)
        case .navFilter(id, agentFilter, let value, _):
            return .agent(value)
        case .navFilter(id, viewFilter, let value, _):
            return WorkLogic.ActivityFilter(rawValue: value).map(Action.filter)
        case .navPicker(id, viewPicker, let value):
            return value == "activity" ? .overview : .open(WorkLogic.tasksHref(project: project), newTab: false)
        case .navSearch(id, searchId, let value):
            return .search(value)
        case .navActivate(id, let item, let newTab):
            if item == overviewItem { return .overview }
            if item == loadMoreItem { return .loadMore }
            if item == retryItem { return .retry }
            if item.hasPrefix("run:") { return .openRun(String(item.dropFirst(4)), newTab: newTab) }
            if item.hasPrefix("needs:") { return .openNeeds(String(item.dropFirst(6)), newTab: newTab) }
            return nil
        default:
            return nil
        }
    }
}
