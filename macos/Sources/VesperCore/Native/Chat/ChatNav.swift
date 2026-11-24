import Foundation

/// Chat list sidebar `NavModel` builder and command mapper.
/// Mirrors `web/lib/native-shell/chats-model.ts` with local-day grouping (`Today`, `Yesterday`,
/// `Previous 7 days`, `Older`), pinned/running/unread indicators, search, and space/persona filters.
public enum ChatNav {
    public static let id = "chats"
    public static let newChatAction = "new-chat"
    public static let newSpaceAction = "new-space"
    public static let personaPicker = "persona"
    public static let viewAction = "chats-view"
    public static let viewActive = "view-active"
    public static let viewArchived = "view-archived"
    public static let searchId = "chat-search"
    public static let spaceFilter = "chat-space"
    public static let personaFilter = "chat-persona"
    public static let startWithPrefix = "start-with:"
    public static let hitPrefix = "hit:"
    public static let spacePrefix = "space:"

    /// `persona_id` for GET /chats from the sidebar's persona pick. The "All" pick ("") must send
    /// `all` explicitly: the server reads an omitted `persona_id` as the caller's default persona.
    public static func listPersonaQuery(_ selectedPersonaId: String) -> String {
        selectedPersonaId.isEmpty ? "all" : selectedPersonaId
    }

    public enum MenuAction {
        public static let openInNewTab = "open-new-tab"
        public static let rename = "rename"
        public static let pin = "pin"
        public static let unpin = "unpin"
        public static let archive = "archive"
        public static let restore = "restore"
        public static let delete = "delete"
    }

    public enum ViewMode: String, Sendable, Equatable, Hashable {
        case active
        case archived
    }

    public enum RowMark: String, Sendable, Equatable, Hashable {
        case running
        case unread
    }

    public enum DayBucket: String, Sendable, Equatable, Hashable, CaseIterable {
        case pinned = "Pinned"
        case today = "Today"
        case yesterday = "Yesterday"
        case previous7Days = "Previous 7 days"
        case older = "Older"

        public var sectionId: String {
            switch self {
            case .pinned: return "chats-pinned"
            case .today: return "chats-today"
            case .yesterday: return "chats-yesterday"
            case .previous7Days: return "chats-previous-7-days"
            case .older: return "chats-older"
            }
        }
    }

    public struct ChatRow: Sendable, Equatable {
        public var id: String
        public var title: String
        public var state: String
        public var unread: Int
        public var pinned: Bool
        public var temporary: Bool
        public var archived: Bool
        public var lastMessageAt: String?
        public var createdAt: String
        public var spaceId: String?
        public var personaId: String?
        public var personaName: String?
        public var personaColor: String?
        public var personaAvatarUrl: String?
        public var participantNames: [String]

        public init(
            id: String,
            title: String,
            state: String = "idle",
            unread: Int = 0,
            pinned: Bool = false,
            temporary: Bool = false,
            archived: Bool = false,
            lastMessageAt: String? = nil,
            createdAt: String,
            spaceId: String? = nil,
            personaId: String? = nil,
            personaName: String? = nil,
            personaColor: String? = nil,
            personaAvatarUrl: String? = nil,
            participantNames: [String] = []
        ) {
            self.id = id
            self.title = title
            self.state = state
            self.unread = unread
            self.pinned = pinned
            self.temporary = temporary
            self.archived = archived
            self.lastMessageAt = lastMessageAt
            self.createdAt = createdAt
            self.spaceId = spaceId
            self.personaId = personaId
            self.personaName = personaName
            self.personaColor = personaColor
            self.personaAvatarUrl = personaAvatarUrl
            self.participantNames = participantNames
        }

        public init(_ session: API.ChatSession, pinned: Bool = false) {
            self.init(
                id: session.id,
                title: session.title,
                state: session.state.rawValue,
                unread: session.unread,
                pinned: pinned,
                temporary: session.temporary ?? false,
                archived: session.archived,
                lastMessageAt: session.lastMessageAt,
                createdAt: session.createdAt,
                spaceId: session.space?.id,
                personaId: session.persona?.id,
                personaName: session.persona?.name,
                personaColor: session.persona?.color,
                personaAvatarUrl: session.persona?.avatarUrl,
                participantNames: (session.participants ?? []).map(\.name)
            )
        }
    }

    public struct SearchHit: Sendable, Equatable {
        public var messageId: String
        public var chatId: String
        public var chatTitle: String
        public var role: String
        public var archived: Bool
        public var personaName: String?
        public var snippet: String

        public init(
            messageId: String, chatId: String, chatTitle: String,
            role: String, archived: Bool = false, personaName: String? = nil, snippet: String
        ) {
            self.messageId = messageId; self.chatId = chatId; self.chatTitle = chatTitle
            self.role = role; self.archived = archived; self.personaName = personaName; self.snippet = snippet
        }

        public init(_ hit: API.ChatSearchHit) {
            self.init(
                messageId: hit.messageId, chatId: hit.chatId, chatTitle: hit.chatTitle,
                role: hit.role.rawValue, archived: hit.archived, personaName: hit.personaName, snippet: hit.snippet
            )
        }
    }

    public enum SearchState: Sendable, Equatable {
        case short
        case pending
        case error(String)
        case ready([SearchHit])
    }

    public struct SpaceRow: Sendable, Equatable {
        public var id: String
        public var name: String
        public var color: String?
        public var chatCount: Int?
        public var workKey: String?
        public var workArchived: Bool

        public init(id: String, name: String, color: String? = nil, chatCount: Int? = nil, workKey: String? = nil, workArchived: Bool = false) {
            self.id = id; self.name = name; self.color = color; self.chatCount = chatCount
            self.workKey = workKey; self.workArchived = workArchived
        }

        public init(_ space: API.ChatSpace) {
            self.init(
                id: space.id, name: space.name, color: space.color.rawValue,
                chatCount: space.chatCount, workKey: space.work?.key, workArchived: space.work?.archived ?? false
            )
        }
    }

    public struct FilterOption: Sendable, Equatable {
        public var value: String
        public var label: String

        public init(value: String, label: String) {
            self.value = value; self.label = label
        }
    }

    public struct Group: Sendable, Equatable {
        public var bucket: DayBucket
        public var chats: [ChatRow]

        public init(bucket: DayBucket, chats: [ChatRow]) {
            self.bucket = bucket; self.chats = chats
        }
    }

    public struct Input: Sendable {
        public var chats: [ChatRow] = []
        public var viewedChatId: String?
        public var viewedSpaceId: String?
        public var spaces: [SpaceRow] = []
        public var selectedSpaceId: String = ""
        public var personas: [FilterOption] = []
        public var selectedPersonaId: String = ""
        public var view: ViewMode = .active
        public var query: String = ""
        public var searchState: SearchState?
        public var filteredToPersona: (id: String, name: String)?
        public var error: String?
        public var newChatDisabled: Bool = false
        public var origin: URL?
        public var now: Date = Date()
        public var calendar: Calendar = .current

        public init() {}
    }

    // MARK: - Helpers

    public static func chatTitle(_ raw: String) -> String {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? "New conversation" : t
    }

    /// Running wins over unread; the currently open chat never shows an unread dot.
    public static func rowMark(state: String, unread: Int, isOpen: Bool) -> RowMark? {
        if state == "running" { return .running }
        return !isOpen && unread > 0 ? .unread : nil
    }

    public static func filterChats(
        _ chats: [ChatRow],
        query: String = "",
        spaceId: String = "",
        personaId: String = ""
    ) -> [ChatRow] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return chats.filter { row in
            if !spaceId.isEmpty && row.spaceId != spaceId { return false }
            if !personaId.isEmpty && row.personaId != personaId { return false }
            if !q.isEmpty {
                let titleMatch = row.title.lowercased().contains(q)
                let personaMatch = row.personaName?.lowercased().contains(q) ?? false
                let participantMatch = row.participantNames.contains { $0.lowercased().contains(q) }
                if !titleMatch && !personaMatch && !participantMatch { return false }
            }
            return true
        }
    }

    /// Groups chats into `Pinned`, `Today`, `Yesterday`, `Previous 7 days`, and `Older` using local calendar day boundaries.
    public static func groupByDay(
        _ chats: [ChatRow],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [Group] {
        let startToday = calendar.startOfDay(for: now)
        let startYesterday = calendar.date(byAdding: .day, value: -1, to: startToday) ?? startToday.addingTimeInterval(-86_400)
        let start7Days = calendar.date(byAdding: .day, value: -7, to: startToday) ?? startToday.addingTimeInterval(-7 * 86_400)

        var buckets: [DayBucket: [ChatRow]] = [:]
        for chat in chats {
            if chat.pinned {
                buckets[.pinned, default: []].append(chat)
                continue
            }
            let date = APIDate.parse(chat.lastMessageAt ?? chat.createdAt) ?? Date.distantPast
            let bucket: DayBucket
            if date >= startToday {
                bucket = .today
            } else if date >= startYesterday {
                bucket = .yesterday
            } else if date >= start7Days {
                bucket = .previous7Days
            } else {
                bucket = .older
            }
            buckets[bucket, default: []].append(chat)
        }

        return DayBucket.allCases.compactMap { bucket in
            guard let list = buckets[bucket], !list.isEmpty else { return nil }
            return Group(bucket: bucket, chats: list)
        }
    }

    public static func avatar(name: String, color: String?, imageUrl: String?, origin: URL?) -> Avatar {
        let literal = color.flatMap { c in
            let low = c.lowercased()
            return (low.hasPrefix("#") || low.hasPrefix("rgb") || low.hasPrefix("hsl")) ? c : nil
        }
        let resolvedImage = imageUrl.flatMap { raw -> String? in
            guard !raw.isEmpty else { return nil }
            return URL(string: raw, relativeTo: origin)?.absoluteURL.absoluteString
        }
        return Avatar(initials: WorkNav.initials(name), color: literal, imageUrl: resolvedImage)
    }

    public static func chatMenu(archived: Bool, pinned: Bool) -> [MenuItem] {
        let openInNewTab: [MenuItem] = [
            MenuItem(id: MenuAction.openInNewTab, label: "Open in New Tab", icon: "external"),
            MenuItem(id: "sep-open", separator: true),
        ]
        if archived {
            return openInNewTab + [
                MenuItem(id: MenuAction.restore, label: "Restore", icon: "refresh"),
                MenuItem(id: "sep", separator: true),
                MenuItem(id: MenuAction.delete, label: "Delete…", icon: "trash", destructive: true),
            ]
        }
        return openInNewTab + [
            MenuItem(id: pinned ? MenuAction.unpin : MenuAction.pin, label: pinned ? "Unpin" : "Pin", icon: "pin"),
            MenuItem(id: MenuAction.rename, label: "Rename…", icon: "edit"),
            MenuItem(id: MenuAction.archive, label: "Archive", icon: "folder"),
            MenuItem(id: "sep", separator: true),
            MenuItem(id: MenuAction.delete, label: "Delete…", icon: "trash", destructive: true),
        ]
    }

    public static func chatItem(
        _ chat: ChatRow,
        viewedChatId: String?,
        origin: URL?,
        now: Date,
        calendar: Calendar,
        archived: Bool
    ) -> NavItem {
        let isOpen = chat.id == viewedChatId
        let mark = rowMark(state: chat.state, unread: chat.unread, isOpen: isOpen)
        var sub: [String] = []
        if chat.pinned { sub.append("Pinned") }
        if chat.state == "failed" { sub.append("Failed") }
        if chat.temporary { sub.append("Temporary") }
        if chat.participantNames.count > 1 { sub.append(chat.participantNames.joined(separator: ", ")) }

        return NavItem(
            id: chat.id,
            title: chatTitle(chat.title),
            subtitle: sub.isEmpty ? nil : sub.joined(separator: " · "),
            avatar: nil,
            badge: mark == .unread ? NavBadge(text: "\(chat.unread)", tone: .human) : nil,
            status: mark == .running ? .done : nil,
            trailing: mark == .unread ? nil : APIDate.shortAgo(chat.lastMessageAt ?? chat.createdAt, now: now, calendar: calendar),
            href: archived ? "/chat/\(chat.id)?view=archived" : "/chat/\(chat.id)",
            contextMenu: chatMenu(archived: archived, pinned: chat.pinned)
        )
    }

    public static func hitItem(_ hit: SearchHit) -> NavItem {
        let cleanSnippet = hit.snippet
            .replacingOccurrences(of: "\u{E000}", with: "")
            .replacingOccurrences(of: "\u{E001}", with: "")
        return NavItem(
            id: "\(hitPrefix)\(hit.messageId)",
            title: chatTitle(hit.chatTitle),
            subtitle: cleanSnippet,
            badge: hit.archived ? NavBadge(text: "Archived") : nil,
            trailing: hit.role == "user" ? "You" : (hit.personaName ?? "Assistant"),
            href: "/chat/\(hit.chatId)?message=\(hit.messageId)",
            contextMenu: [MenuItem(id: MenuAction.openInNewTab, label: "Open in New Tab", icon: "external")]
        )
    }

    // MARK: - NavModel Builder

    public static func model(_ input: Input) -> NavModel {
        let archived = input.view == .archived
        let query = input.query
        let filteredChats = filterChats(
            input.chats,
            query: input.searchState == nil ? query : "",
            spaceId: input.selectedSpaceId,
            personaId: input.selectedPersonaId
        )

        var sections: [NavSection]
        if !query.isEmpty, let searchState = input.searchState {
            let items: [NavItem]
            let emptyText: String
            switch searchState {
            case .ready(let hits):
                items = hits.map(hitItem)
                emptyText = "No messages match."
            case .error(let msg):
                items = []
                emptyText = msg
            case .pending:
                items = []
                emptyText = "Searching…"
            case .short:
                items = []
                emptyText = "Keep typing…"
            }
            sections = [NavSection(id: "chat-search-results", title: "Search results", items: items, emptyText: emptyText)]
        } else if archived {
            let items = filteredChats.map {
                chatItem($0, viewedChatId: input.viewedChatId, origin: input.origin, now: input.now, calendar: input.calendar, archived: true)
            }
            sections = [NavSection(id: "chats-archived", title: "Archived", items: items, emptyText: input.error ?? "No archived conversations.")]
        } else {
            let groups = groupByDay(filteredChats, now: input.now, calendar: input.calendar)
            sections = groups.map { group in
                NavSection(
                    id: group.bucket.sectionId,
                    title: group.bucket.rawValue,
                    items: group.chats.map {
                        chatItem($0, viewedChatId: input.viewedChatId, origin: input.origin, now: input.now, calendar: input.calendar, archived: false)
                    }
                )
            }
            if sections.isEmpty {
                let empty = input.error ?? (query.isEmpty ? "No conversations yet" : "No chats match.")
                sections = [NavSection(id: "chats", title: "Chats", items: [], emptyText: empty)]
            }
            if let persona = input.filteredToPersona, input.error == nil {
                sections[sections.count - 1].items.append(
                    NavItem(id: "\(startWithPrefix)\(persona.id)", title: "New chat with \(persona.name)", icon: "plus")
                )
            }
        }

        if !input.newChatDisabled, !sections.isEmpty {
            sections[0].actions = [NavAction(id: newChatAction, label: "New Chat", icon: "compose", showsLabel: true)]
        }

        let viewMenu: [MenuItem] = [
            MenuItem(id: viewActive, label: "Recent", checked: !archived),
            MenuItem(id: viewArchived, label: "Archived", icon: "folder", checked: archived),
        ]

        return NavModel(
            id: id,
            title: "Chat",
            actions: [NavAction(id: viewAction, label: "View", icon: "folder", menu: viewMenu)],
            picker: nil,
            filters: nil,
            search: NavSearch(id: searchId, placeholder: "Find in chats", value: query),
            sections: sections,
            selectedId: input.viewedChatId
        )
    }

    // MARK: - Command Mapper

    public enum Action: Sendable, Equatable {
        case newChat(personaId: String?)
        case newSpace
        case selectChat(id: String, newTab: Bool)
        case selectSearchHit(messageId: String, newTab: Bool)
        case selectSpace(id: String, newTab: Bool)
        case selectView(ViewMode)
        case filterSpace(String)
        case filterPersona(String)
        case pickPersona(String)
        case search(String)
        case renameChat(id: String)
        case pinChat(id: String, pinned: Bool)
        case archiveChat(id: String)
        case restoreChat(id: String)
        case deleteChat(id: String)
    }

    public static func action(for command: NativeCommand) -> Action? {
        switch command {
        case .navAction(id, newChatAction, _, _):
            return .newChat(personaId: nil)
        case .navAction(id, newSpaceAction, _, _):
            return .newSpace
        case .navAction(id, viewAction, _, let menuItemId):
            switch menuItemId {
            case viewActive: return .selectView(.active)
            case viewArchived: return .selectView(.archived)
            case newSpaceAction: return .newSpace
            default: return nil
            }
        case .navAction(id, let actionId, let itemId, _):
            guard let itemId else { return nil }
            switch actionId {
            case MenuAction.openInNewTab:
                if itemId.hasPrefix(hitPrefix) {
                    return .selectSearchHit(messageId: String(itemId.dropFirst(hitPrefix.count)), newTab: true)
                }
                if itemId.hasPrefix(spacePrefix) {
                    return .selectSpace(id: String(itemId.dropFirst(spacePrefix.count)), newTab: true)
                }
                return .selectChat(id: itemId, newTab: true)
            case MenuAction.rename: return .renameChat(id: itemId)
            case MenuAction.pin: return .pinChat(id: itemId, pinned: true)
            case MenuAction.unpin: return .pinChat(id: itemId, pinned: false)
            case MenuAction.archive: return .archiveChat(id: itemId)
            case MenuAction.restore: return .restoreChat(id: itemId)
            case MenuAction.delete: return .deleteChat(id: itemId)
            default: return nil
            }
        case .navPicker(id, personaPicker, let value):
            return .pickPersona(value)
        case .navFilter(id, spaceFilter, let value, _):
            return .filterSpace(value)
        case .navFilter(id, personaFilter, let value, _):
            return .filterPersona(value)
        case .navSearch(id, searchId, let value):
            return .search(value)
        case .navActivate(id, let item, let newTab):
            if item.hasPrefix(startWithPrefix) {
                return .newChat(personaId: String(item.dropFirst(startWithPrefix.count)))
            }
            if item.hasPrefix(hitPrefix) {
                return .selectSearchHit(messageId: String(item.dropFirst(hitPrefix.count)), newTab: newTab)
            }
            if item.hasPrefix(spacePrefix) {
                return .selectSpace(id: String(item.dropFirst(spacePrefix.count)), newTab: newTab)
            }
            return .selectChat(id: item, newTab: newTab)
        default:
            return nil
        }
    }
}
