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

/// Pure formatting, context-marker, pinning, and starter helpers for native Companion Chat
/// (`app:work`) and Knowledge Chat (`app:knowledge` / `page:<id>`), matching `web/lib/work-context.ts`
/// and `web/app/(app)/knowledge/_components/knowledge-dock.tsx`.
public enum WorkCompanionLogic {
    /// Server cuts message text at this marker (`server/internal/runs/chat_personas.go`).
    public static let workContextMarker = "\n\n<!-- vesper:work-context -->\n"
    public static let knowledgeContextMarker = "\n\n<!-- vesper:knowledge-context -->\n"

    public static func workContextLine(_ subject: CompanionSubject, pinned: Bool = false) -> String {
        let verb = pinned ? "Pinned" : "Viewing"
        switch subject.kind {
        case .ticket:
            return "\(verb) ticket \(subject.id) (\u{201C}\(subject.title)\u{201D})."
        case .run:
            let agent = subject.agent ?? "agent"
            let ticketSuffix = subject.ticketKey.map { " for ticket \($0)" } ?? ""
            return "\(verb) run \(subject.id) (\u{201C}\(subject.title)\u{201D}) by \(agent)\(ticketSuffix)."
        }
    }

    public static func sameSubject(_ a: CompanionSubject, _ b: CompanionSubject) -> Bool {
        a.kind == b.kind && a.id == b.id
    }

    /// Appends the viewing/pinned work context after `workContextMarker` once.
    public static func withWorkContext(
        _ body: String,
        viewing: CompanionSubject?,
        pinned: CompanionSubject? = nil
    ) -> String {
        let same = pinned != nil && viewing != nil && sameSubject(pinned!, viewing!)
        var lines: [String] = []
        if let pinned, !same {
            lines.append(workContextLine(pinned, pinned: true))
        }
        if let viewing {
            lines.append(workContextLine(viewing, pinned: same))
        }
        guard !lines.isEmpty else { return body }
        let suffix = "\(workContextMarker)\(lines.joined(separator: "\n"))"
        return body.hasSuffix(suffix) ? body : "\(body)\(suffix)"
    }

    public static func workSubjectLabel(_ subject: CompanionSubject) -> String {
        switch subject.kind {
        case .ticket:
            return "\(subject.id) \u{00B7} \(subject.title)"
        case .run:
            if let key = subject.ticketKey, !key.isEmpty {
                return "\(key) \u{00B7} \(subject.title)"
            }
            return subject.title
        }
    }

    public static func mergeWorkContextRefs(
        existing: [API.ChatContextRef]?,
        viewing: CompanionSubject?,
        pinned: CompanionSubject?
    ) -> [API.ChatContextRef]? {
        var refs = existing ?? []
        for subject in [pinned, viewing].compactMap({ $0 }) {
            let key: String? = switch subject.kind {
            case .ticket: subject.id
            case .run: subject.ticketKey
            }
            if let key, !key.isEmpty, !refs.contains(where: { $0.kind == .ticket && $0.key == key }) {
                refs.append(API.ChatContextRef(key: key, kind: .ticket))
            }
        }
        return refs.isEmpty ? nil : refs
    }

    public static func workWelcome(for subject: CompanionSubject?) -> (whereText: String, intro: String, starters: [DockedChatStarter]) {
        guard let subject else {
            return (
                "beside this page",
                "One chat that follows you around Vesper. Pin a run or ticket from its page to keep it attached here.",
                [
                    DockedChatStarter(
                        icon: "checkmark.circle",
                        title: "What did my agents finish?",
                        prompt: "What did my agents finish since yesterday, and what's waiting on me?"
                    ),
                    DockedChatStarter(
                        icon: "magnifyingglass",
                        title: "What needs me?",
                        prompt: "What needs me right now, most urgent first?"
                    ),
                ]
            )
        }
        switch subject.kind {
        case .run:
            return (
                "beside the run",
                "I can read this run, its ticket and its history, and talk it through with you. Replies to the agent go in the main pane.",
                [
                    DockedChatStarter(
                        icon: "magnifyingglass",
                        title: "What is it doing?",
                        prompt: "Summarise what this run has done so far and what it's doing now."
                    ),
                    DockedChatStarter(
                        icon: "checkmark.shield",
                        title: "Is it safe to approve?",
                        prompt: "Is it safe to approve what this run is asking for? What could go wrong?"
                    ),
                    DockedChatStarter(
                        icon: "checkmark.circle",
                        title: "Check the criteria",
                        prompt: "Which of this ticket's acceptance criteria has the run met, and which are still open?"
                    ),
                ]
            )
        case .ticket:
            return (
                "beside \(subject.id)",
                "I can read this ticket, its runs and its history, and talk it through with you. Replies to the agent go in the main pane.",
                [
                    DockedChatStarter(
                        icon: "magnifyingglass",
                        title: "Where does it stand?",
                        prompt: "Summarise where this ticket stands: its runs, what's done and what's left."
                    ),
                    DockedChatStarter(
                        icon: "pencil",
                        title: "Tighten the criteria",
                        prompt: "Suggest clearer acceptance criteria for this ticket."
                    ),
                ]
            )
        }
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
