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
}

public enum LandingLogic {
    public static func needsWizard(me: API.User?) -> Bool {
        guard let me else { return false }
        if me.onboardedAt == nil || me.onboardedAt?.isEmpty == true { return true }
        return me.harnessConnected == false
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
