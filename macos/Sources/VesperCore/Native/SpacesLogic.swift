import Foundation

/// Pure helpers and declarative inspector builder for native Spaces (`/spaces/new`, `/spaces/:id`),
/// matching `web/lib/spaces.ts` and `web/lib/native-shell/models/space-inspector.ts`.
public enum SpacesLogic {
    public enum ChatSort: String, CaseIterable, Sendable, Identifiable {
        case newest
        case oldest
        public var id: String { rawValue }
        public var label: String { self == .newest ? "Newest" : "Oldest" }
    }

    public static let pageChatsLimit = 5
    public static let maxInstructions = 4000

    /// Request for every chat in a space regardless of persona.
    public static func spaceChatsRequest(spaceId: String) -> APIRequest<API.ListChatsResponse> {
        API.listChats(personaId: "all", space: spaceId)
    }

    /// Request for every chat across spaces regardless of persona.
    public static let allSpaceChatsRequest: APIRequest<API.ListChatsResponse> = API.listChats(
        personaId: "all",
        space: "all"
    )

    public static func colorHex(for color: API.ChatSpaceColor) -> String {
        switch color {
        case .green: "#34D399"
        case .amber: "#FBBF24"
        case .red: "#F87171"
        case .blue: "#60A5FA"
        case .violet: "#A78BFA"
        case .pink: "#F472B6"
        case .teal: "#2DD4BF"
        case .orange: "#FB923C"
        default: "#34D399"
        }
    }

    public static func colorLabel(for color: API.ChatSpaceColor) -> String {
        color.rawValue.prefix(1).uppercased() + color.rawValue.dropFirst()
    }

    public static func initial(for name: String) -> String {
        for ch in name where ch.isLetter || ch.isNumber {
            return String(ch).uppercased()
        }
        return "#"
    }

    public static func formatTokens(_ n: Int, precise: Bool = false) -> String {
        if n < 1000 { return "\(n)" }
        let k = Double(n) / 1000.0
        if precise || k < 10 {
            let rounded = (k * 10).rounded() / 10
            if rounded == rounded.rounded() {
                return "\(Int(rounded))k"
            }
            return String(format: "%.1fk", rounded)
        }
        return "\(Int(k.rounded()))k"
    }

    public static func bareURL(_ raw: String) -> String {
        guard let url = URL(string: raw), let host = url.host else { return raw }
        let cleanHost = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        let combined = "\(cleanHost)\(url.path)"
        return combined.hasSuffix("/") ? String(combined.dropLast()) : combined
    }

    public static func sourceKindLabel(_ kind: API.ChatSpaceSourceKind) -> String {
        switch kind {
        case .file: "File"
        case .text: "Text"
        case .website: "Website"
        case .library: "Library"
        case .link: "Saved link"
        case .canvas: "Canvas"
        case .research: "Research"
        default: "Source"
        }
    }

    public static func sourceName(_ source: API.ChatSpaceSource) -> String {
        if source.kind == .website, let url = source.url, !url.isEmpty {
            return bareURL(url)
        }
        return source.title
    }

    public static func sourceDetail(_ source: API.ChatSpaceSource) -> String {
        let kind = sourceKindLabel(source.kind)
        if source.tokens > 0 {
            return "\(kind) \u{00B7} \(formatTokens(source.tokens, precise: true)) tokens"
        }
        return "\(kind) \u{00B7} \(ChatCodeReviewLogic.formatBytes(source.sizeBytes))"
    }

    public static func sortChats(_ chats: [API.ChatSession], sort: ChatSort) -> [API.ChatSession] {
        chats.sorted { a, b in
            let ta = APIDate.parse(a.lastMessageAt ?? a.createdAt) ?? .distantPast
            let tb = APIDate.parse(b.lastMessageAt ?? b.createdAt) ?? .distantPast
            return sort == .newest ? ta > tb : ta < tb
        }
    }

    public static func inFlightChats(_ chats: [API.ChatSession]) -> [API.ChatSession] {
        sortChats(chats.filter { $0.state == .running || $0.unread > 0 }, sort: .newest)
    }

    public static func activeBranches(_ branches: [API.ChatSpaceBranch]) -> [API.ChatSpaceBranch] {
        branches.filter(\.active)
    }

    public static func closedBranches(_ branches: [API.ChatSpaceBranch]) -> [API.ChatSpaceBranch] {
        branches.filter { !$0.active }
    }

    public static func branchStatusLabel(for branch: API.ChatSpaceBranch) -> String {
        if let prState = branch.prState {
            switch prState {
            case .merged: return branch.active ? "New commits" : "Merged"
            case .closed: return branch.active ? "New commits" : "Closed"
            case .draft: return "Draft PR"
            case .open: return "Open PR"
            default: break
            }
        }
        if let pushState = branch.pushState {
            switch pushState {
            case "staging", "pending": return "Pending push"
            case "pushing": return "Pushing"
            case "pushed": return branch.prUrl != nil ? "Open PR" : "Pushed"
            case "declined": return branch.active ? "Local edits" : "Declined"
            case "failed": return "Push failed"
            default: break
            }
        }
        if branch.live { return "Editing" }
        if branch.dirty { return "Uncommitted" }
        return "Local branch"
    }

    public static func sortSpacesByActivity(_ spaces: [API.ChatSpace]) -> [API.ChatSpace] {
        spaces.sorted { a, b in
            let ta = APIDate.parse(a.lastActivityAt ?? a.updatedAt) ?? .distantPast
            let tb = APIDate.parse(b.lastActivityAt ?? b.updatedAt) ?? .distantPast
            if ta != tb { return ta > tb }
            let cmp = a.name.localizedStandardCompare(b.name)
            return cmp == .orderedSame ? a.id < b.id : cmp == .orderedAscending
        }
    }

    public static func subtitle(for space: API.ChatSpace) -> String {
        func plural(_ count: Int, _ noun: String) -> String {
            "\(count) \(noun)\(count == 1 ? "" : "s")"
        }
        var parts: [String] = []
        let desc = space.description.trimmingCharacters(in: .whitespacesAndNewlines)
        if !desc.isEmpty { parts.append(desc) }
        if let rc = space.repoCount, rc > 0 { parts.append(plural(rc, "repo")) }
        if let kc = space.knowledgeCount, kc > 0 { parts.append(plural(kc, "Knowledge link")) }
        if let tc = space.openTaskCount, tc > 0 { parts.append(plural(tc, "open task")) }
        parts.append(plural(space.chatCount, "chat"))
        if space.sourceCount > 0 { parts.append(plural(space.sourceCount, "source")) }
        return parts.joined(separator: " \u{00B7} ")
    }

    public static func usesSummary(for space: API.ChatSpace) -> String {
        var parts: [String] = []
        if !space.instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append("\(space.name)\u{2019}s instructions")
        }
        if let rc = space.repoCount, rc > 0 {
            parts.append("\(rc) repo\(rc == 1 ? "" : "s")")
        }
        if let kc = space.knowledgeCount, kc > 0 {
            parts.append("\(kc) Knowledge link\(kc == 1 ? "" : "s")")
        }
        if space.sourceCount > 0 {
            parts.append("\(space.sourceCount) source\(space.sourceCount == 1 ? "" : "s")")
        }
        if space.spaceMemory {
            parts.append("space memory")
        }
        guard !parts.isEmpty else { return "New chats here start in \(space.name)." }
        let last = parts.removeLast()
        if parts.isEmpty { return "Uses \(last)" }
        return "Uses \(parts.joined(separator: ", ")) and \(last)"
    }

    public static func buildAboutInspectorSections(
        space: API.ChatSpace,
        sources: [API.ChatSpaceSource],
        inlineBudget: Int,
        inlineTokens: Int,
        personas: [API.Persona],
        connectorsSummary: String
    ) -> [InspectorSection] {
        var sections: [InspectorSection] = []

        // Instructions
        let trimmedInstructions = space.instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        sections.append(InspectorSection(
            id: "instructions",
            title: "Instructions",
            items: [
                InspectorItem(
                    id: "instructions_text",
                    kind: .note,
                    detail: trimmedInstructions.isEmpty ? "No custom instructions yet. Open Edit space to add some." : trimmedInstructions
                ),
                InspectorItem(
                    id: "instructions_edit",
                    kind: .actions,
                    actions: [InspectorAction(id: "edit_space", label: "Edit space", icon: "gear")]
                ),
            ]
        ))

        // Sources
        var sourceItems: [InspectorItem] = []
        if !sources.isEmpty {
            sourceItems.append(InspectorItem(
                id: "source_list",
                kind: .list,
                rows: sources.prefix(5).map { s in
                    NavItem(id: s.id, title: sourceName(s), trailing: sourceKindLabel(s.kind))
                }
            ))
        }
        let fraction = inlineBudget > 0 ? min(1.0, Double(inlineTokens) / Double(inlineBudget)) : 0
        sourceItems.append(InspectorItem(
            id: "inline_budget",
            kind: .progress,
            label: "Inline context",
            detail: "\(formatTokens(inlineTokens)) of \(formatTokens(inlineBudget)) inline",
            tone: .accent,
            fraction: fraction
        ))
        sourceItems.append(InspectorItem(
            id: "source_actions",
            kind: .actions,
            actions: [
                InspectorAction(
                    id: "manage_sources",
                    label: sources.count > 5 ? "Manage all \(sources.count)" : "Manage sources",
                    icon: "artifacts"
                ),
            ]
        ))
        sections.append(InspectorSection(id: "sources", title: "Sources", aside: "\(space.sourceCount)", items: sourceItems))

        // Memory
        var memoryItems: [InspectorItem] = [
            InspectorItem(
                id: "space_memory",
                kind: .toggle,
                label: "Space memory",
                detail: space.spaceMemory
                    ? "Isolated in \(space.name); general memory still read."
                    : "Chats read and update general memory.",
                checked: space.spaceMemory
            ),
        ]
        if space.memoryCount > 0 {
            memoryItems.append(InspectorItem(
                id: "memories_link",
                kind: .fact,
                label: "Saved",
                value: "\(space.memoryCount) \(space.memoryCount == 1 ? "memory" : "memories")",
                href: "/settings?section=spaces&space=\(space.id)"
            ))
        }
        sections.append(InspectorSection(id: "memory", title: "Memory", items: memoryItems))

        // Defaults
        let personaOptions = [InspectorOption(value: "", label: "Default persona")]
            + personas.map { InspectorOption(value: $0.id, label: $0.name) }
        let defaultItems: [InspectorItem] = [
            InspectorItem(
                id: "persona_id",
                kind: .picker,
                label: "Persona",
                value: space.personaId ?? "",
                options: personaOptions
            ),
            InspectorItem(
                id: "connectors",
                kind: .fact,
                label: "Connectors",
                value: connectorsSummary
            ),
        ]
        sections.append(InspectorSection(id: "defaults", title: "Defaults", items: defaultItems))

        return sections
    }

    // MARK: - Sidebar NavModel

    public static let navId = "spaces"
    public static let newSpaceAction = "new-space"
    public static let spacePrefix = "space:"
    public static let chatPrefix = "chat:"
    public static let newChatPrefix = "new-chat:"
    public static let openNewTabMenu = "open-new-tab"

    public static func navModel(
        spaces: [API.ChatSpace],
        activeSpaceId: String?,
        chats: [API.ChatSession] = [],
        viewedChatId: String? = nil,
        personas: [API.Persona] = [],
        origin: URL? = nil
    ) -> NavModel {
        let personaById = Dictionary(uniqueKeysWithValues: personas.map { ($0.id, $0) })
        let sortedChats = sortChats(chats, sort: .newest)

        let spaceItems = spaces.map { sp -> NavItem in
            let isActive = sp.id == activeSpaceId
            let assignedPersona = sp.personaId.flatMap { personaById[$0] }
            let rowAvatar: Avatar
            if let assigned = assignedPersona, !assigned.isDefault {
                rowAvatar = ChatNav.avatar(
                    name: assigned.name,
                    color: assigned.color,
                    imageUrl: assigned.avatarUrl,
                    origin: origin
                )
            } else {
                rowAvatar = Avatar(initials: initial(for: sp.name), color: colorHex(for: sp.color))
            }

            var children: [NavItem]?
            if isActive {
                var rows = sortedChats.prefix(5).map { chat in
                    let isRunning = chat.state == .running
                    return NavItem(
                        id: "\(chatPrefix)\(chat.id)",
                        title: chat.title.isEmpty ? "New chat" : chat.title,
                        badge: chat.unread > 0 && chat.id != viewedChatId
                            ? NavBadge(text: "\(chat.unread)", tone: .human)
                            : nil,
                        status: isRunning ? .done : nil,
                        href: "/chat/\(chat.id)",
                        contextMenu: [MenuItem(id: openNewTabMenu, label: "Open in New Tab", icon: "external")]
                    )
                }
                rows.append(NavItem(
                    id: "\(newChatPrefix)\(sp.id)",
                    title: "New chat",
                    icon: "plus",
                    href: "/spaces/\(sp.id)"
                ))
                children = rows
            }

            let hasRunning = isActive && sortedChats.contains(where: { $0.state == .running })
            return NavItem(
                id: "\(spacePrefix)\(sp.id)",
                title: sp.name,
                avatar: rowAvatar,
                status: hasRunning ? .done : nil,
                trailing: sp.chatCount > 0 ? "\(sp.chatCount)" : nil,
                href: "/spaces/\(sp.id)",
                children: children,
                expanded: isActive ? true : nil,
                contextMenu: [MenuItem(id: openNewTabMenu, label: "Open in New Tab", icon: "external")]
            )
        }

        let sections: [NavSection] = [
            NavSection(
                id: "spaces",
                title: "Spaces",
                items: spaceItems,
                badge: spaceItems.isEmpty ? nil : NavBadge(text: "\(spaceItems.count)"),
                emptyText: "No spaces yet."
            ),
        ]

        let selectedId: String? = if let viewedChatId {
            "\(chatPrefix)\(viewedChatId)"
        } else if let activeSpaceId {
            "\(spacePrefix)\(activeSpaceId)"
        } else {
            nil
        }

        return NavModel(
            id: navId,
            title: "Spaces",
            actions: [
                NavAction(id: newSpaceAction, label: "New space", icon: "plus", accent: true),
            ],
            sections: sections,
            selectedId: selectedId
        )
    }

    public enum NavActionResult: Sendable, Equatable {
        case newSpace
        case openSpace(String, newTab: Bool)
        case openChat(String, newTab: Bool)
    }

    public static func navAction(for command: NativeCommand) -> NavActionResult? {
        switch command {
        case .navAction(navId, newSpaceAction, _, _):
            return .newSpace
        case .navAction(navId, openNewTabMenu, let itemId?, _):
            if itemId.hasPrefix(spacePrefix) {
                return .openSpace(String(itemId.dropFirst(spacePrefix.count)), newTab: true)
            }
            if itemId.hasPrefix(chatPrefix) {
                return .openChat(String(itemId.dropFirst(chatPrefix.count)), newTab: true)
            }
            return nil
        case .navActivate(navId, let itemId, let newTab):
            if itemId.hasPrefix(spacePrefix) {
                return .openSpace(String(itemId.dropFirst(spacePrefix.count)), newTab: newTab)
            }
            if itemId.hasPrefix(newChatPrefix) {
                return .openSpace(String(itemId.dropFirst(newChatPrefix.count)), newTab: newTab)
            }
            if itemId.hasPrefix(chatPrefix) {
                return .openChat(String(itemId.dropFirst(chatPrefix.count)), newTab: newTab)
            }
            return nil
        default:
            return nil
        }
    }

    // MARK: - Knowledge Link Autocomplete

    public struct KnowledgeLinkSuggestion: Sendable, Equatable, Hashable, Identifiable {
        public var id: String { "\(kind.rawValue):\(path)" }
        public var kind: API.ChatSpaceKnowledgeLinkKind
        public var path: String
        public var title: String
        public var subtitle: String?
        public var pageCount: Int?

        public init(
            kind: API.ChatSpaceKnowledgeLinkKind,
            path: String,
            title: String,
            subtitle: String? = nil,
            pageCount: Int? = nil
        ) {
            self.kind = kind
            self.path = path
            self.title = title
            self.subtitle = subtitle
            self.pageCount = pageCount
        }
    }

    /// Filters and ranks Knowledge folder or page suggestions for the Space Knowledge-link input.
    public static func knowledgeLinkSuggestions(
        query: String,
        kind: API.ChatSpaceKnowledgeLinkKind,
        pages: [KnowledgePageRow],
        existingLinks: [API.ChatSpaceKnowledgeLink] = [],
        limit: Int = 8
    ) -> [KnowledgeLinkSuggestion] {
        guard limit > 0 else { return [] }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedQuery = KnowledgeShellLogic.normalizeFolderPath(trimmed)
        let qLower = (normalizedQuery.isEmpty ? trimmed : normalizedQuery).lowercased()
        let existingPaths = Set(
            existingLinks
                .filter { $0.kind == kind }
                .map { KnowledgeShellLogic.normalizeFolderPath($0.path).lowercased() }
        )

        if kind == .folder {
            let tree = KnowledgeShellLogic.buildTree(from: pages, prioritizeInbox: false)
            var folders: [(path: String, name: String, count: Int)] = []
            func walk(_ node: KnowledgeTreeFolder) {
                for child in node.folders {
                    folders.append((path: child.path, name: child.name, count: child.count))
                    walk(child)
                }
            }
            walk(tree)

            var scored: [(rank: Int, path: String, count: Int)] = []
            for f in folders {
                let pathLower = f.path.lowercased()
                if existingPaths.contains(pathLower) { continue }
                if qLower.isEmpty {
                    scored.append((0, f.path, f.count))
                    continue
                }
                let nameLower = f.name.lowercased()
                let rank: Int
                if pathLower == qLower || nameLower == qLower {
                    rank = 0
                } else if nameLower.hasPrefix(qLower) {
                    rank = 1
                } else if pathLower.hasPrefix(qLower) {
                    rank = 2
                } else if nameLower.contains(qLower) {
                    rank = 3
                } else if pathLower.contains(qLower) {
                    rank = 4
                } else {
                    continue
                }
                scored.append((rank, f.path, f.count))
            }

            scored.sort { lhs, rhs in
                if lhs.rank != rhs.rank { return lhs.rank < rhs.rank }
                let cmp = lhs.path.localizedStandardCompare(rhs.path)
                return cmp == .orderedSame ? lhs.path < rhs.path : cmp == .orderedAscending
            }

            return scored.prefix(limit).map { item in
                KnowledgeLinkSuggestion(
                    kind: .folder,
                    path: item.path,
                    title: "\(item.path)/",
                    subtitle: "\(item.count) page\(item.count == 1 ? "" : "s")",
                    pageCount: item.count
                )
            }
        }

        // Page suggestions
        var seenPaths = Set<String>()
        var scored: [(rank: Int, updatedAt: String, path: String, title: String, parent: String)] = []
        for page in pages {
            let normPath = KnowledgeShellLogic.normalizeFolderPath(page.path)
            guard !normPath.isEmpty else { continue }
            let pathLower = normPath.lowercased()
            if existingPaths.contains(pathLower) || !seenPaths.insert(pathLower).inserted { continue }

            let trimmedTitle = page.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let displayTitle = trimmedTitle.isEmpty ? KnowledgeShellLogic.nameOf(normPath) : trimmedTitle
            let titleLower = displayTitle.lowercased()
            let parent = KnowledgeShellLogic.parentOf(normPath)

            let rank: Int
            if qLower.isEmpty {
                rank = 0
            } else if titleLower == qLower || pathLower == qLower {
                rank = 0
            } else if titleLower.hasPrefix(qLower) {
                rank = 1
            } else if pathLower.hasPrefix(qLower) {
                rank = 2
            } else if titleLower.contains(qLower) {
                rank = 3
            } else if pathLower.contains(qLower) {
                rank = 4
            } else {
                continue
            }
            scored.append((rank, page.updatedAt, normPath, displayTitle, parent))
        }

        scored.sort { lhs, rhs in
            if lhs.rank != rhs.rank { return lhs.rank < rhs.rank }
            if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
            let cmp = lhs.path.localizedStandardCompare(rhs.path)
            return cmp == .orderedSame ? lhs.path < rhs.path : cmp == .orderedAscending
        }

        return scored.prefix(limit).map { item in
            KnowledgeLinkSuggestion(
                kind: .page,
                path: item.path,
                title: item.title,
                subtitle: item.parent.isEmpty ? nil : item.parent
            )
        }
    }
}

public extension API.ChatSpaceBranch {
    var spaceBranchKey: String { "\(chatId)|\(repoUrl)|\(branch)" }
}
