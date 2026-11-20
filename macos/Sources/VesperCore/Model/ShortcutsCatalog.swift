import Foundation

public struct ShortcutEntry: Sendable, Hashable, Identifiable {
    public var id: String { "\(sectionId):\(label)" }
    public let sectionId: String
    public let label: String
    public let keys: [String]

    public init(sectionId: String, label: String, keys: [String]) {
        self.sectionId = sectionId
        self.label = label
        self.keys = keys
    }
}

public struct ShortcutSection: Sendable, Hashable, Identifiable {
    public var id: String { title }
    public let title: String
    public let items: [ShortcutEntry]

    public init(title: String, items: [(String, [String])]) {
        self.title = title
        self.items = items.map { ShortcutEntry(sectionId: title, label: $0.0, keys: $0.1) }
    }

    public init(title: String, entries: [ShortcutEntry]) {
        self.title = title
        self.items = entries
    }
}

/// Keyboard shortcut reference shown in the native Shortcuts window (Help › Keyboard Shortcuts, `?` / `⌘/`).
public enum KeyboardShortcutsCatalog: Sendable {
    public static let allSections: [ShortcutSection] = [
        ShortcutSection(title: "Global", items: [
            ("Open command palette", ["⌘", "K"]),
            ("Open page-scoped command palette", ["⌘", "⇧", "K"]),
            ("Toolbar search", ["⌘", "⌥", "F"]),
            ("Find in page", ["⌘", "F"]),
            ("Find next / previous", ["⌘", "G", "⇧⌘G"]),
            ("Use selection for find", ["⌘", "E"]),
            ("Quick Look selected item", ["Space"]),
            ("Show keyboard shortcuts", ["?"]),
        ]),
        ShortcutSection(title: "Window & Tabs", items: [
            ("New tab", ["⌘", "T"]),
            ("Reopen closed tab", ["⌘", "⇧", "T"]),
            ("Close tab", ["⌘", "W"]),
            ("Next / previous tab", ["⌃", "Tab"]),
            ("Toggle sidebar", ["⌘", "⌃", "S"]),
            ("Toggle right inspector", ["⌘", "\\"]),
            ("Settings", ["⌘", ","]),
        ]),
        ShortcutSection(title: "Work", items: [
            ("New ticket", ["C"]),
        ]),
        ShortcutSection(title: "Chat", items: [
            ("Next / previous message", ["J", "K"]),
            ("Reply to the message (quote it)", ["R"]),
            ("Start a thread on the message", ["T"]),
            ("Edit your last message", ["E"]),
            ("Back to the message box", ["Esc"]),
        ]),
        ShortcutSection(title: "Palette", items: [
            ("Move / open / close", ["↑", "↓", "↵", "Esc"]),
            ("Next / previous type", ["Tab", "⇧Tab"]),
            ("Expand / collapse a chat's matching messages", ["→", "←"]),
            ("Attach to a chat", ["⌥", "↵"]),
            ("People · tickets · commands only", ["@", "#", ">"]),
            ("Open in a new tab", ["⌘", "↵"]),
        ]),
        ShortcutSection(title: "Ticket", items: [
            ("Next / previous ticket", ["J", "K"]),
            ("Edit the ticket", ["E"]),
            ("Save description / comment", ["⌘", "↵"]),
        ]),
        ShortcutSection(title: "Needs you tray", items: [
            ("Next / previous item", ["J", "K"]),
            ("Open the item's page", ["↵"]),
            ("Switch between Needs you and Updates", ["←", "→"]),
            ("Approve the selected approval", ["A"]),
            ("Deny the selected approval", ["D"]),
            ("Reply to the selected question", ["R"]),
            ("Clear the selected item until it changes", ["X"]),
            ("Close the tray, or leave the reply box", ["Esc"]),
        ]),
        ShortcutSection(title: "Inbox", items: [
            ("Next / previous item", ["J", "K"]),
            ("Open the item's page", ["↵"]),
            ("Approve (approvals, mockups)", ["A"]),
            ("Deny (approvals)", ["D"]),
            ("Reply (questions) or focus the note", ["R"]),
            ("Mark done: hide until it changes", ["E"]),
            ("Send the reply or note", ["⌘", "↵"]),
            ("Leave the text box, back to the list", ["Esc"]),
        ]),
        ShortcutSection(title: "Knowledge", items: [
            ("Go to page", ["⌘", "O"]),
            ("Quick capture", ["⌘", "⌥", "N"]),
            ("Today's daily note", ["⌘", "D"]),
            ("Close active tab", ["⌥", "W"]),
            ("Close all tabs", ["⌥", "⇧", "W"]),
        ]),
    ]

    public static func filter(_ sections: [ShortcutSection] = allSections, query: String) -> [ShortcutSection] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return sections }
        let needle = trimmed.lowercased()
        return sections.compactMap { section in
            if section.title.lowercased().contains(needle) {
                return section
            }
            let matching = section.items.filter { entry in
                entry.label.lowercased().contains(needle)
                    || entry.keys.joined(separator: " ").lowercased().contains(needle)
            }
            return matching.isEmpty ? nil : ShortcutSection(title: section.title, entries: matching)
        }
    }
}
