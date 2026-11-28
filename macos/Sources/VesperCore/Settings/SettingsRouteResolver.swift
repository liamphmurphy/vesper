import Foundation

/// Every section shown in the unified native Settings window (personal, personas, integrations, workspace, account, and Mac App).
public enum SettingsPane: String, CaseIterable, Sendable, Hashable, Codable {
    // Personal
    case you
    case appearance
    case memory
    case promptTemplates = "prompt-templates"
    // Personas
    case personas
    // Integrations
    case secrets
    case connectors
    case mail
    case repositories
    // Workspace
    case workspace
    case runners
    case devWorkspace = "dev-workspace"
    case spaces
    // Account
    case signIn = "sign-in"
    // Mac App
    case general
    case notifications
    case shortcuts
    case files
    case workspaces
    case power
    case backups
    case security
    case companion
    case updates
}

public enum SettingsPersonaFilter: String, CaseIterable, Sendable, Equatable, Hashable {
    case all, chat, tickets
}

public enum SettingsSecretsTab: String, CaseIterable, Sendable, Equatable, Hashable {
    case provider, api
}

/// Typed destination resolved from `/settings*`, `/customization*`, `/memory`, `/personas`, or `/agents`.
public enum SettingsDestination: Sendable, Equatable {
    case pane(
        pane: SettingsPane,
        personaId: String? = nil,
        personaFilter: SettingsPersonaFilter = .all,
        memoryFocusId: String? = nil,
        secretsTab: SettingsSecretsTab = .provider,
        secretId: String? = nil,
        spaceId: String? = nil,
        anchor: String? = nil,
        runnerRunId: String? = nil
    )
    case spaceRedirect(projectKey: String?)

    public var pane: SettingsPane? {
        if case .pane(let pane, _, _, _, _, _, _, _, _) = self { return pane }
        return nil
    }
}

/// Swift port of `web/lib/settings-nav.ts` plus `/settings/runner`, `/settings/projects`,
/// `/customization*`, `/memory`, `/personas`, and `/agents` link resolution.
public enum SettingsRouteResolver {
    public static let defaultPane: SettingsPane = .you

    private static let simpleWebSections: [String: SettingsPane] = [
        "you": .you,
        "appearance": .appearance,
        "prompt-templates": .promptTemplates,
        "templates": .promptTemplates,
        "connectors": .connectors,
        "mail": .mail,
        "repositories": .repositories,
        "runners": .runners,
        "dev-workspace": .devWorkspace,
        "sign-in": .signIn,
        "backup": .backups,
        "backups": .backups,
    ]

    private static let macSections: [String: SettingsPane] = [
        "general": .general,
        "notifications": .notifications,
        "shortcuts": .shortcuts,
        "files": .files,
        "workspaces": .workspaces,
        "power": .power,
        "backups": .backups,
        "security": .security,
        "companion": .companion,
        "updates": .updates,
    ]

    /// Extra keywords per pane for Settings sidebar filtering (`web/lib/settings-nav.ts`).
    public static let filterKeywords: [SettingsPane: String] = [
        .you: "profile account name email avatar bio about",
        .appearance: "theme dark light mode font text size palette colors harness activity",
        .memory: "memories facts import export forget everything",
        .promptTemplates: "prompt templates slash commands macros snippets clipboard variables",
        .personas: "personas agents models roles permissions tickets",
        .secrets: "provider credentials api secrets keys tokens oauth anthropic openai google github ssh pat",
        .connectors: "mcp servers tools oauth integration",
        .repositories: "repos github owners organizations presets discovery",
        .companion: "iphone ios mobile companion tailscale lan qr pair remote",
        .workspace: "setup checklist encryption secrets_key image engine generation codex antigravity media providers music video omni tts voice speech lyria gemini",
        .runners: "runner backends microvm docker fake concurrency slots host folders environment test",
        .devWorkspace: "nix lazyvim neovim tmux gitconfig container ssh dev",
        .spaces: "space memory overrides skills project instructions",
        .signIn: "password authentication login browser session",
        .backups: "export archive zip migrate move restore instance encrypt encryption password time machine",
        .general: "menu bar dock login launch layout tabs",
        .notifications: "alerts sound quiet hours approvals",
        .shortcuts: "hotkey keyboard quick capture screenshot show hide",
        .files: "dock drop deep links universal links",
        .workspaces: "terminal editor ghostty iterm vscode zed",
        .power: "sleep battery thermal quit stack postgres runner slots",
        .security: "touch id biometric sign-in",
        .updates: "auto check feed version sparkle",
    ]

    /// Resolves an arbitrary path or URL string (`/settings?...`, `/customization?who=...`, `/memory`, etc.)
    /// into a `SettingsDestination`, or returns `nil` when the URL does not target Settings.
    public static func resolve(_ raw: String) -> SettingsDestination? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let url = URL(string: trimmed, relativeTo: URL(string: "http://vesper.local"))
        guard let url else { return nil }
        return resolve(url)
    }

    /// Resolves a parsed `URL` (full origin or relative against a base URL).
    public static func resolve(_ url: URL) -> SettingsDestination? {
        var path = url.path
        if path.count > 1 {
            while path.hasSuffix("/") { path.removeLast() }
        }
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: true)
        let items = comps?.queryItems ?? []
        let hash = comps?.fragment ?? ""

        if path == "/memory" {
            return resolveSettingsQuery(items, hash: hash, forcedSection: "memory")
        }
        if path == "/personas" {
            return resolveSettingsQuery(items, hash: hash, forcedSection: "personas")
        }
        // Only exact `/agents` moved to Settings; `/agents/:handle` stays the agent editor.
        if path == "/agents" {
            var patched = items.filter { $0.name != "section" && $0.name != "filter" }
            patched.append(URLQueryItem(name: "section", value: "personas"))
            if let existingFilter = queryValue("filter", in: items), !existingFilter.isEmpty {
                patched.append(URLQueryItem(name: "filter", value: existingFilter))
            } else {
                patched.append(URLQueryItem(name: "filter", value: "tickets"))
            }
            return resolveSettingsQuery(patched, hash: hash)
        }
        if path == "/customization" || path.hasPrefix("/customization/") {
            return resolveCustomization(items, hash: hash)
        }
        if path == "/settings/projects" {
            return .spaceRedirect(projectKey: nonEmpty(queryValue("project", in: items)))
        }
        if path == "/settings/runner" {
            return .pane(pane: .runners, runnerRunId: nonEmpty(queryValue("run_id", in: items)))
        }
        if path == "/settings" {
            return resolveSettingsQuery(items, hash: hash)
        }
        if path.hasPrefix("/settings/") {
            let sub = String(path.dropFirst("/settings/".count))
            if let direct = simpleWebSections[sub] ?? macSections[sub] {
                return resolveSettingsQuery(items, hash: hash, forcedSection: direct == .backups ? "backup" : direct.rawValue)
            }
            if sub == "secrets" || sub == "spaces" || sub == "workspace" || sub == "memory" || sub == "personas" {
                return resolveSettingsQuery(items, hash: hash, forcedSection: sub)
            }
            return resolveSettingsQuery(items, hash: hash)
        }
        return nil
    }

    private static func resolveCustomization(_ items: [URLQueryItem], hash: String) -> SettingsDestination {
        if let space = nonEmpty(queryValue("space", in: items)) {
            let normHash = normalizeHash(hash)
            return .pane(pane: .spaces, spaceId: space, anchor: normHash == "overrides" ? "overrides" : nil)
        }
        if let who = nonEmpty(queryValue("who", in: items)) {
            switch who {
            case "person":
                return .pane(pane: .you)
            case "personas":
                return .pane(pane: .personas, personaFilter: .all)
            case "agents":
                return .pane(pane: .personas, personaFilter: .tickets)
            case "connectors":
                return .pane(pane: .connectors)
            case "secrets":
                return .pane(pane: .secrets, secretsTab: .api, secretId: nonEmpty(queryValue("secret", in: items)))
            default:
                return .pane(pane: .personas, personaId: who)
            }
        }
        return .pane(pane: .memory, memoryFocusId: nonEmpty(queryValue("id", in: items)))
    }

    private static func resolveSettingsQuery(_ items: [URLQueryItem], hash: String, forcedSection: String? = nil) -> SettingsDestination {
        let normHash = normalizeHash(hash)
        let section = forcedSection ?? queryValue("section", in: items)

        if let section, !section.isEmpty {
            if let pane = simpleWebSections[section] {
                if pane == .runners {
                    return .pane(pane: .runners, runnerRunId: nonEmpty(queryValue("run_id", in: items)))
                }
                return .pane(pane: pane)
            }
            if let pane = macSections[section] {
                return .pane(pane: pane)
            }
            if section == "memory" {
                return .pane(pane: .memory, memoryFocusId: nonEmpty(queryValue("id", in: items)))
            }
            if section == "personas" {
                if let personaId = nonEmpty(queryValue("persona", in: items)) {
                    return .pane(pane: .personas, personaId: personaId)
                }
                return .pane(pane: .personas, personaFilter: parsePersonaFilter(queryValue("filter", in: items)))
            }
            if section == "persona" {
                if let personaId = nonEmpty(queryValue("persona", in: items)) ?? nonEmpty(queryValue("id", in: items)) {
                    return .pane(pane: .personas, personaId: personaId)
                }
                return .pane(pane: .personas, personaFilter: .all)
            }
            if section == "secrets" {
                let secretId = nonEmpty(queryValue("secret", in: items))
                let tab = queryValue("tab", in: items)
                let secretsTab: SettingsSecretsTab = (tab == "api" || (secretId != nil && tab != "provider")) ? .api : .provider
                return .pane(pane: .secrets, secretsTab: secretsTab, secretId: secretId)
            }
            if section == "workspace" {
                let anchor = (normHash == "images" || normHash == "media") ? normHash : nil
                return .pane(pane: .workspace, anchor: anchor)
            }
            if section == "spaces" {
                return .pane(pane: .spaces, spaceId: nonEmpty(queryValue("space", in: items)), anchor: normHash == "overrides" ? "overrides" : nil)
            }
        }

        if let personaId = nonEmpty(queryValue("persona", in: items)) {
            return .pane(pane: .personas, personaId: personaId)
        }
        if let focusId = nonEmpty(queryValue("id", in: items)) {
            return .pane(pane: .memory, memoryFocusId: focusId)
        }
        if let spaceId = nonEmpty(queryValue("space", in: items)) {
            return .pane(pane: .spaces, spaceId: spaceId, anchor: normHash == "overrides" ? "overrides" : nil)
        }
        if let secretId = nonEmpty(queryValue("secret", in: items)) {
            return .pane(pane: .secrets, secretsTab: .api, secretId: secretId)
        }

        switch normHash {
        case "workspace": return .pane(pane: .workspace)
        case "spaces": return .pane(pane: .spaces)
        case "memory": return .pane(pane: .memory)
        case "personas": return .pane(pane: .personas, personaFilter: .all)
        case "secrets": return .pane(pane: .secrets, secretsTab: .provider)
        case "images": return .pane(pane: .workspace, anchor: "images")
        case "media": return .pane(pane: .workspace, anchor: "media")
        case "overrides": return .pane(pane: .spaces, anchor: "overrides")
        default:
            if let pane = simpleWebSections[normHash] ?? macSections[normHash] {
                return .pane(pane: pane)
            }
            return .pane(pane: defaultPane)
        }
    }

    /// True when every whitespace-separated word in `query` matches `label` or `extra` (case-insensitive).
    public static func matchesFilter(_ query: String, label: String, extra: String? = nil) -> Bool {
        let words = query.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .split(whereSeparator: { $0.isWhitespace })
        if words.isEmpty { return true }
        let hay = "\(label) \(extra ?? "")".lowercased()
        return words.allSatisfy { hay.contains($0) }
    }

    /// Returns whether every word in `query` matches the pane's title or its indexed keywords.
    public static func matchesPane(_ pane: SettingsPane, title: String, query: String) -> Bool {
        matchesFilter(query, label: title, extra: filterKeywords[pane])
    }

    private static func queryValue(_ name: String, in items: [URLQueryItem]) -> String? {
        items.first(where: { $0.name == name })?.value
    }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let s, !s.isEmpty else { return nil }
        return s
    }

    private static func parsePersonaFilter(_ raw: String?) -> SettingsPersonaFilter {
        guard let raw, let f = SettingsPersonaFilter(rawValue: raw) else { return .all }
        return f
    }

    private static func normalizeHash(_ hash: String) -> String {
        let stripped = hash.hasPrefix("#") ? String(hash.dropFirst()) : hash
        return (stripped.removingPercentEncoding ?? stripped).lowercased()
    }
}
