import Foundation

/// Standalone Runs list in the sidebar beside `/runs/:id`.
/// Swift port of `web/lib/native-shell/models/runs.ts` (keep command IDs in step).
public enum RunsNav {
    public static let id = "runs"
    public static let loadMoreItem = "load-more"
    public static let retryItem = "retry"
    public static let hideDoneValue = "hide-done"
    public static let optionsFilter = "run-options"
    public static let spaceFilter = "run-space"
    public static let agentFilter = "run-agent"
    public static let searchId = "run-search"
    public static let statusItem = "status"

    public static func runItemId(_ id: String) -> String { "run:\(id)" }
    public static func needsItemId(_ id: String) -> String { "needs:\(id)" }

    public struct RunRow: Sendable, Equatable {
        public var id: String
        public var title: String
        public var subtitle: String?
        public var avatar: Avatar?
        public var trailing: String
        public var dot: WorkLogic.Dot

        public init(
            id: String,
            title: String,
            subtitle: String? = nil,
            avatar: Avatar? = nil,
            trailing: String,
            dot: WorkLogic.Dot
        ) {
            self.id = id
            self.title = title
            self.subtitle = subtitle
            self.avatar = avatar
            self.trailing = trailing
            self.dot = dot
        }
    }

    public struct NeedsRow: Sendable, Equatable {
        public var id: String
        public var title: String
        public var subtitle: String?
        public var avatar: Avatar?
        public var trailing: String
        public var tone: Tone

        public init(
            id: String,
            title: String,
            subtitle: String? = nil,
            avatar: Avatar? = nil,
            trailing: String,
            tone: Tone = .human
        ) {
            self.id = id
            self.title = title
            self.subtitle = subtitle
            self.avatar = avatar
            self.trailing = trailing
            self.tone = tone
        }
    }

    public struct Group: Sendable, Equatable {
        public var key: String
        public var label: String
        public var count: Int?
        public var runs: [RunRow]

        public init(key: String, label: String, count: Int? = nil, runs: [RunRow]) {
            self.key = key
            self.label = label
            self.count = count
            self.runs = runs
        }
    }

    public struct Input: Sendable {
        public var project: String?
        public var projects: [(key: String, name: String, archived: Bool)] = []
        public var agents: [(handle: String, name: String)] = []
        public var agent: String = ""
        public var hideDone = false
        public var search: String = ""
        public var needs: [NeedsRow] = []
        public var groups: [Group] = []
        public var loading = false
        public var error: String?
        public var hasMore = false
        public var loadingMore = false
        public var statusLine: (text: String, href: String)?
        public var selectedId: String?

        public init() {}
    }

    private static let dotTones: [WorkLogic.Dot: Tone] = [
        .human: .human,
        .running: .done,
        .failed: .blocked,
        .queued: .neutral,
    ]

    public static func selectedItemId(runId: String, needs: [API.InboxItem]) -> String {
        if let item = needs.first(where: { $0.runId == runId }) {
            return needsItemId(item.id)
        }
        return runItemId(runId)
    }

    public static func model(_ input: Input) -> NavModel {
        let filters: [NavFilterMenu] = [
            NavFilterMenu(
                id: optionsFilter,
                label: "View",
                icon: "sliders",
                options: [NavFilterOption(value: hideDoneValue, label: "Hide done", checked: input.hideDone)],
                multiple: true
            ),
            NavFilterMenu(
                id: spaceFilter,
                label: "Space",
                icon: "briefcase",
                options: [NavFilterOption(value: "", label: "All spaces", checked: (input.project ?? "").isEmpty)]
                    + input.projects
                        .filter { !$0.archived || $0.key == input.project }
                        .map { NavFilterOption(value: $0.key, label: $0.name, checked: input.project == $0.key) }
            ),
            NavFilterMenu(
                id: agentFilter,
                label: "Persona",
                icon: "agents",
                options: [NavFilterOption(value: "", label: "All personas", checked: input.agent.isEmpty)]
                    + input.agents.map { NavFilterOption(value: $0.handle, label: $0.name, checked: input.agent == $0.handle) }
            ),
        ]

        var sections: [NavSection] = []
        if let status = input.statusLine, !status.text.isEmpty {
            sections.append(NavSection(
                id: "status",
                items: [NavItem(id: statusItem, title: status.text, icon: "activity", href: status.href)]
            ))
        }
        sections += bodySections(input)

        return NavModel(
            id: id,
            title: "Runs",
            filters: filters,
            search: NavSearch(id: searchId, placeholder: "Search runs", value: input.search),
            sections: sections,
            selectedId: input.selectedId
        )
    }

    private static func bodySections(_ input: Input) -> [NavSection] {
        let needsSection: [NavSection] = input.needs.isEmpty ? [] : [
            NavSection(
                id: "needs-you",
                title: "Needs you",
                items: input.needs.map { row in
                    NavItem(
                        id: needsItemId(row.id),
                        title: row.title,
                        subtitle: row.subtitle,
                        icon: row.avatar == nil ? "inbox" : nil,
                        avatar: row.avatar,
                        status: row.tone,
                        trailing: row.trailing
                    )
                },
                badge: NavBadge(text: "\(input.needs.count)")
            ),
        ]

        if let error = input.error {
            return needsSection + [
                NavSection(
                    id: "error",
                    items: [NavItem(id: retryItem, title: "Couldn\u{2019}t load runs. \(error)", subtitle: "Retry", icon: "refresh")]
                ),
            ]
        }

        if input.loading {
            return needsSection + [NavSection(id: "loading", items: [], emptyText: "Loading")]
        }

        let groups = input.groups.map { group in
            NavSection(
                id: "runs-\(group.key)",
                title: group.label,
                items: group.runs.map { run in
                    NavItem(
                        id: runItemId(run.id),
                        title: run.title,
                        subtitle: run.subtitle,
                        avatar: run.avatar,
                        status: dotTones[run.dot],
                        trailing: run.trailing
                    )
                },
                badge: group.count.map { NavBadge(text: "\($0)") }
            )
        }

        if groups.isEmpty && needsSection.isEmpty {
            let emptyText = input.search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "No runs yet. Start one from a ticket or a chat."
                : "No runs match."
            return [NavSection(id: "empty", items: [], emptyText: emptyText)]
        }

        var out = needsSection + groups
        if input.hasMore {
            out.append(NavSection(
                id: "more",
                items: [NavItem(id: loadMoreItem, title: "Load older runs", icon: "history", disabled: input.loadingMore)]
            ))
        }
        return out
    }

    public enum Action: Sendable, Equatable {
        case search(String)
        case toggleHideDone(Bool)
        case project(String)
        case agent(String)
        case loadMore
        case retry
        case openRun(String, newTab: Bool)
        case openNeeds(String, newTab: Bool)
        case openStatus(newTab: Bool)
    }

    public static func action(for command: NativeCommand) -> Action? {
        switch command {
        case .navSearch(id, searchId, let value):
            return .search(value)
        case .navFilter(id, optionsFilter, hideDoneValue, let checked):
            return .toggleHideDone(checked)
        case .navFilter(id, spaceFilter, let value, _):
            return .project(value)
        case .navFilter(id, agentFilter, let value, _):
            return .agent(value)
        case .navActivate(id, let item, let newTab):
            if item == loadMoreItem { return .loadMore }
            if item == retryItem { return .retry }
            if item == statusItem { return .openStatus(newTab: newTab) }
            if item.hasPrefix("run:") { return .openRun(String(item.dropFirst(4)), newTab: newTab) }
            if item.hasPrefix("needs:") { return .openNeeds(String(item.dropFirst(6)), newTab: newTab) }
            return nil
        default:
            return nil
        }
    }
}
