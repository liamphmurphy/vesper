import Foundation

public struct DockedChatStarter: Sendable, Equatable, Identifiable {
    public let id: String
    public let icon: String
    public let title: String
    public let prompt: String

    public init(id: String? = nil, icon: String, title: String, prompt: String) {
        self.id = id ?? title
        self.icon = icon
        self.title = title
        self.prompt = prompt
    }
}

/// Pure formatting, context-marker, and starter helpers for native Companion Chat
/// (`app:work`) and Knowledge Chat (`app:knowledge` / `page:<id>`).
public enum WorkCompanionLogic {
    /// Server cuts message text at this marker (`server/internal/runs/chat_personas.go`).
    public static let knowledgeContextMarker = "\n\n<!-- vesper:knowledge-context -->\n"

    public static func companionWelcome() -> (whereText: String, intro: String, starters: [DockedChatStarter]) {
        (
            "beside this page",
            "One chat that follows you around Vesper.",
            [
                DockedChatStarter(
                    icon: "magnifyingglass",
                    title: "What needs me?",
                    prompt: "What needs me right now, most urgent first?"
                ),
            ]
        )
    }

    public static func knowledgeContextBody(
        _ body: String,
        pagePath: String?,
        pageTitle: String?,
        screen: String?,
        unsavedDraft: String? = nil,
        savedBody: String? = nil
    ) -> String {
        var blocks: [String] = []
        if let title = pageTitle, !title.isEmpty {
            let label = "[[\(pagePath?.isEmpty == false ? pagePath! : title)]]"
            blocks.append("Currently viewing Knowledge page \(label).")
            if let draft = unsavedDraft,
               draft.trimmingCharacters(in: .whitespacesAndNewlines) != (savedBody ?? "").trimmingCharacters(in: .whitespacesAndNewlines) {
                let quoted = draft.split(separator: "\n", omittingEmptySubsequences: false).map { "> \($0)" }.joined(separator: "\n")
                blocks.append("Current editor text of \(label) (includes unsaved edits; use this over the saved page):\n\(quoted)")
            }
        } else if let screen, !screen.isEmpty {
            blocks.append("On the Knowledge \(screen) screen, not viewing a page.")
        }
        guard !blocks.isEmpty else { return body }
        let suffix = "\(knowledgeContextMarker)\(blocks.joined(separator: "\n\n"))"
        return body.hasSuffix(suffix) ? body : "\(body)\(suffix)"
    }

    public static func knowledgeWelcome(pageTitle: String?, screen: String?) -> (whereText: String, intro: String, starters: [DockedChatStarter]) {
        if let pageTitle, !pageTitle.isEmpty {
            return (
                "on \u{201C}\(pageTitle)\u{201D}",
                "I can read this page, link it and suggest edits you accept or reject.",
                [
                    DockedChatStarter(
                        icon: "doc.text",
                        title: "Summarise this page",
                        prompt: "Summarise this page in three lines, and suggest adding it as a TL;DR at the top."
                    ),
                    DockedChatStarter(
                        icon: "link",
                        title: "Suggest links",
                        prompt: "Find mentions of other pages in this one that aren't linked yet, and propose links."
                    ),
                    DockedChatStarter(
                        icon: "magnifyingglass",
                        title: "Find related pages",
                        prompt: "Which of my pages are related to this one? Group them by how they relate."
                    ),
                    DockedChatStarter(
                        icon: "pencil",
                        title: "Tidy tags and properties",
                        prompt: "Suggest tags and properties for this page that match the pages beside it."
                    ),
                ]
            )
        }
        let suffix = (screen != nil && screen != "Home") ? "in Knowledge \u{00B7} \(screen!)" : "in Knowledge"
        return (
            suffix,
            "Ask about your notes. I can search, link, tag and write pages with you.",
            [
                DockedChatStarter(
                    icon: "tray",
                    title: "File my inbox",
                    prompt: "Look at the captures in my Inbox and suggest a folder or page for each. Don't move anything until I say."
                ),
                DockedChatStarter(
                    icon: "point.3.connected.trianglepath.dotted",
                    title: "Connect orphan pages",
                    prompt: "Find pages nothing links to and propose links to them from related pages."
                ),
                DockedChatStarter(
                    icon: "clock",
                    title: "What did I write this week?",
                    prompt: "Summarise the pages I created or edited this week."
                ),
                DockedChatStarter(
                    icon: "pencil",
                    title: "Start today's note",
                    prompt: "Start today's daily note, carrying over anything still open from my last one."
                ),
            ]
        )
    }
}
