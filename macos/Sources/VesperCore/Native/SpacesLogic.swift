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

    public static func subtitle(for space: API.ChatSpace) -> String {
        func plural(_ count: Int, _ noun: String) -> String {
            "\(count) \(noun)\(count == 1 ? "" : "s")"
        }
        var parts: [String] = []
        let desc = space.description.trimmingCharacters(in: .whitespacesAndNewlines)
        if !desc.isEmpty { parts.append(desc) }
        parts.append(plural(space.chatCount, "chat"))
        parts.append(plural(space.sourceCount, "source"))
        return parts.joined(separator: " \u{00B7} ")
    }

    public static func usesSummary(for space: API.ChatSpace) -> String {
        var parts: [String] = []
        if !space.instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append("\(space.name)\u{2019}s instructions")
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

    public static func isValidWorkKey(_ key: String) -> Bool {
        key.trimmingCharacters(in: .whitespacesAndNewlines)
            .range(of: #"^[A-Za-z][A-Za-z0-9]{1,9}$"#, options: .regularExpression) != nil
    }

    public static func suggestWorkKey(for name: String) -> String {
        let folded = name.folding(options: .diacriticInsensitive, locale: Locale(identifier: "en_US_POSIX"))
        let cleaned = folded.replacingOccurrences(of: "[^A-Za-z0-9\\s]", with: " ", options: .regularExpression)
        let words = cleaned.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let firstIdx = words.firstIndex(where: { $0.first?.isLetter == true }) else { return "" }
        let rest = Array(words[firstIdx...])
        let raw: String
        if rest.count > 1 {
            raw = rest.compactMap(\.first).map(String.init).joined()
        } else {
            raw = String(rest[0].prefix(4))
        }
        let upper = String(raw.uppercased().prefix(10))
        if upper.count >= 2 { return upper }
        var padded = String(rest[0].prefix(4)).uppercased()
        while padded.count < 2 { padded.append("X") }
        return padded
    }

    public static func buildAboutInspectorSections(
        space: API.ChatSpace,
        sources: [API.ChatSpaceSource],
        inlineBudget: Int,
        inlineTokens: Int,
        personas: [API.Persona],
        projectName: String?,
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
                    detail: trimmedInstructions.isEmpty ? "No custom instructions yet. Open Settings to add some." : trimmedInstructions
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
        var defaultItems: [InspectorItem] = [
            InspectorItem(
                id: "persona_id",
                kind: .picker,
                label: "Persona",
                value: space.personaId ?? "",
                options: personaOptions
            ),
        ]
        if space.work == nil {
            defaultItems.append(InspectorItem(
                id: "project",
                kind: .fact,
                label: "New tickets",
                value: projectName ?? "None"
            ))
        }
        defaultItems.append(InspectorItem(
            id: "connectors",
            kind: .fact,
            label: "Connectors",
            value: connectorsSummary
        ))
        sections.append(InspectorSection(id: "defaults", title: "Defaults", items: defaultItems))

        // Work
        let workItems: [InspectorItem]
        if let work = space.work {
            workItems = [
                InspectorItem(
                    id: "work_status",
                    kind: .fact,
                    label: "Status",
                    value: work.archived ? "Archived" : "Tracked",
                    tone: work.archived ? .neutral : .accent
                ),
                InspectorItem(id: "work_key", kind: .fact, label: "Key", value: work.key, mono: true),
                InspectorItem(
                    id: "work_repo",
                    kind: .fact,
                    label: "Repository",
                    value: work.repoUrl.map { ChatCodeReviewLogic.repoName($0) } ?? "None"
                ),
                InspectorItem(id: "work_branch", kind: .fact, label: "Branch", value: work.defaultBranch, mono: true),
            ]
        } else {
            workItems = [
                InspectorItem(
                    id: "work_note",
                    kind: .note,
                    detail: "Not tracking tickets, epics, or runs. Enable Work tracking in Edit space to attach a repository and board."
                ),
            ]
        }
        sections.append(InspectorSection(id: "work", title: "Work", items: workItems))

        return sections
    }
}
