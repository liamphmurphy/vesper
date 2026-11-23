import Foundation

/// Pure logic for `/agents/:handle`: tab normalization, wildcard scope evaluation and tightening,
/// scope change classification, and definition diff summary, matching `web/lib/agent-scopes.ts`.
public enum AgentDetailLogic {
    public enum Tab: String, CaseIterable, Sendable, Identifiable {
        case overview
        case scopes
        case skills
        case memory
        case activity
        case settings
        case tokens

        public var id: String { rawValue }
        public var label: String {
            switch self {
            case .overview: "Overview"
            case .scopes: "Scopes"
            case .skills: "Skills"
            case .memory: "Memory"
            case .activity: "Activity"
            case .settings: "Settings"
            case .tokens: "Tokens"
            }
        }

        public static func from(queryParam raw: String?) -> Tab {
            guard let raw, !raw.isEmpty else { return .overview }
            if let exact = Tab(rawValue: raw) { return exact }
            switch raw {
            case "definition": return .settings
            case "runs": return .activity
            default: return .overview
            }
        }
    }

    public enum ScopeChangeKind: String, Sendable, Equatable {
        case approval
        case widens
        case tightens
        case none
    }

    public struct EffectiveScope: Sendable, Equatable {
        public let mode: API.ScopeMode
        public let source: String // "agent" | "project"
    }

    public struct ScopeRow: Sendable, Equatable, Identifiable {
        public var id: String { scope }
        public let scope: String
        public let definition: API.ScopeMode?
        public let granted: Bool
        public let effective: EffectiveScope
        public let projectOnly: Bool
    }

    public struct ScopeChange: Sendable, Equatable, Identifiable {
        public var id: String { scope }
        public let scope: String
        public let from: API.ScopeMode?
        public let to: API.ScopeMode?
        public let effectiveFrom: API.ScopeMode
        public let effectiveTo: API.ScopeMode
        public let kind: ScopeChangeKind
    }

    private static func rank(_ mode: API.ScopeMode) -> Int {
        switch mode {
        case .allowed: 0
        case .requiresApproval: 1
        default: 2
        }
    }

    public static func stricter(_ a: API.ScopeMode, _ b: API.ScopeMode) -> API.ScopeMode {
        rank(b) > rank(a) ? b : a
    }

    public static func matches(pattern: String, scope: String) -> Bool {
        if pattern == scope { return true }
        return pattern.hasSuffix(":*") && scope.hasPrefix(String(pattern.dropLast()))
    }

    public static func modeFor(scopes: [String: API.ScopeMode]?, scope: String) -> (mode: API.ScopeMode, found: Bool) {
        var best: API.ScopeMode?
        for (pattern, mode) in scopes ?? [:] {
            if matches(pattern: pattern, scope: scope) {
                best = best.map { stricter($0, mode) } ?? mode
            }
        }
        if let best { return (best, true) }
        return (.denied, false)
    }

    /// Mirrors server `agentdef.Resolve`: project overrides can only tighten.
    public static func effectiveMode(
        agent: [String: API.ScopeMode],
        override: [String: API.ScopeMode]?,
        scope: String
    ) -> EffectiveScope {
        let base = modeFor(scopes: agent, scope: scope)
        let proj = modeFor(scopes: override, scope: scope)
        if proj.found {
            let tightened = stricter(base.mode, proj.mode)
            if tightened != base.mode || !base.found {
                return EffectiveScope(mode: tightened, source: "project")
            }
        }
        return EffectiveScope(mode: base.mode, source: "agent")
    }

    public static func scopeRows(
        catalog: [String],
        agent: [String: API.ScopeMode],
        override: [String: API.ScopeMode]?
    ) -> [ScopeRow] {
        var seen = Set<String>()
        var names: [String] = []
        func add(_ s: String) {
            if seen.insert(s).inserted { names.append(s) }
        }
        catalog.forEach(add)
        agent.keys.sorted().forEach(add)
        (override ?? [:]).keys.sorted().forEach(add)
        let catalogSet = Set(catalog)
        return names.map { s in
            ScopeRow(
                scope: s,
                definition: agent[s],
                granted: modeFor(scopes: agent, scope: s).found,
                effective: effectiveMode(agent: agent, override: override, scope: s),
                projectOnly: agent[s] == nil && !catalogSet.contains(s) && override?[s] != nil
            )
        }
    }

    public static func classifyChange(from: API.ScopeMode?, to: API.ScopeMode?) -> ScopeChangeKind {
        let a = from ?? .denied
        let b = to ?? .denied
        if b == .requiresApproval { return .approval }
        return rank(b) < rank(a) ? .widens : .tightens
    }

    public static func scopeChanges(
        before: [String: API.ScopeMode],
        after: [String: API.ScopeMode]
    ) -> [ScopeChange] {
        let names = Set(before.keys).union(after.keys).sorted()
        return names.compactMap { s in
            guard before[s] != after[s] else { return nil }
            let effFrom = modeFor(scopes: before, scope: s).mode
            let effTo = modeFor(scopes: after, scope: s).mode
            let kind: ScopeChangeKind = effFrom == effTo ? .none : classifyChange(from: effFrom, to: effTo)
            return ScopeChange(scope: s, from: before[s], to: after[s], effectiveFrom: effFrom, effectiveTo: effTo, kind: kind)
        }
    }

    public static func summarizeChanges(original: API.AgentDetail, body: API.SaveAgentDefinitionBody) -> [String] {
        var items: [String] = []
        if original.agent.name != body.name { items.append("Name: \(original.agent.name) \u{2192} \(body.name)") }
        if original.agent.role != body.role { items.append("Role updated") }
        if original.specialty != body.specialty { items.append("Specialty updated") }
        if original.spec.harness != body.spec.harness { items.append("Harness: \(original.spec.harness.rawValue) \u{2192} \(body.spec.harness.rawValue)") }
        if original.spec.model != body.spec.model { items.append("Model: \(original.spec.model) \u{2192} \(body.spec.model)") }
        if original.spec.maxConcurrency != body.spec.maxConcurrency { items.append("Max concurrency: \(original.spec.maxConcurrency) \u{2192} \(body.spec.maxConcurrency)") }
        if (original.spec.reviewRequired ?? false) != (body.spec.reviewRequired ?? false) {
            items.append((body.spec.reviewRequired ?? false) ? "Review required enabled" : "Review required disabled")
        }
        if original.spec.instructions != body.spec.instructions { items.append("Instructions updated") }
        let sc = scopeChanges(before: original.spec.scopes, after: body.spec.scopes)
        if !sc.isEmpty { items.append("\(sc.count) scope \(sc.count == 1 ? "change" : "changes")") }
        if (original.spec.skills ?? []) != (body.spec.skills ?? []) { items.append("Skills updated") }
        if original.spec.memory != body.spec.memory { items.append("Memory settings updated") }
        if original.spec.budget != body.spec.budget { items.append("Budget updated") }
        if original.spec.mcpServers != body.spec.mcpServers { items.append("MCP servers updated") }
        return items
    }

    public static func scopeModeLabel(_ mode: API.ScopeMode?) -> String {
        switch mode {
        case .allowed: "Allowed"
        case .requiresApproval: "Approval"
        case .denied: "Denied"
        default: "Not granted"
        }
    }

    // MARK: - Sidebar NavModel

    public static let navId = "agent-detail"
    public static let backToWorkAction = "back-work"
    public static let agentPrefix = "agent:"
    public static let tabPrefix = "tab:"
    public static let openNewTabMenu = "open-new-tab"

    public static func navModel(
        agents: [API.Agent],
        overviews: [API.AgentOverview],
        activeHandle: String,
        activeTab: Tab
    ) -> NavModel {
        let activeCounts = Dictionary(
            overviews.map { ($0.agent.handle, $0.assignments.count) },
            uniquingKeysWith: { a, _ in a }
        )
        let workAgents = agents.filter { $0.kind == .main }
        let list = workAgents.isEmpty ? agents : workAgents
        let agentItems = list.map { agent -> NavItem in
            let tone: Tone? = switch agent.status {
            case .running: .done
            case .waiting: .human
            case .blocked: .blocked
            default: nil
            }
            let busy = activeCounts[agent.handle] ?? 0
            return NavItem(
                id: "\(agentPrefix)\(agent.handle)",
                title: agent.name,
                subtitle: "@\(agent.handle)",
                status: tone,
                trailing: busy > 0 ? "\(busy) active" : nil,
                href: "/agents/\(agent.handle)",
                contextMenu: [MenuItem(id: openNewTabMenu, label: "Open in New Tab", icon: "external")]
            )
        }
        let sectionItems = Tab.allCases.map { tab in
            NavItem(
                id: "\(tabPrefix)\(tab.rawValue)",
                title: tab.label,
                trailing: tab == activeTab ? "Current" : nil
            )
        }

        return NavModel(
            id: navId,
            title: "Agents",
            actions: [NavAction(id: backToWorkAction, label: "Back to Work", icon: "chevl")],
            sections: [
                NavSection(
                    id: "agents",
                    title: "Personas",
                    items: agentItems,
                    badge: agentItems.isEmpty ? nil : NavBadge(text: "\(agentItems.count)"),
                    emptyText: "No agents."
                ),
                NavSection(id: "sections", title: "Sections", items: sectionItems),
            ],
            selectedId: activeHandle.isEmpty ? nil : "\(agentPrefix)\(activeHandle)"
        )
    }

    public enum NavActionResult: Sendable, Equatable {
        case backToWork
        case openAgent(handle: String, newTab: Bool)
        case selectTab(Tab)
    }

    public static func navAction(for command: NativeCommand) -> NavActionResult? {
        switch command {
        case .navAction(navId, backToWorkAction, _, _):
            return .backToWork
        case .navAction(navId, openNewTabMenu, let itemId?, _):
            guard itemId.hasPrefix(agentPrefix) else { return nil }
            return .openAgent(handle: String(itemId.dropFirst(agentPrefix.count)), newTab: true)
        case .navActivate(navId, let itemId, let newTab):
            if itemId.hasPrefix(agentPrefix) {
                return .openAgent(handle: String(itemId.dropFirst(agentPrefix.count)), newTab: newTab)
            }
            if itemId.hasPrefix(tabPrefix) {
                let raw = String(itemId.dropFirst(tabPrefix.count))
                return Tab(rawValue: raw).map(NavActionResult.selectTab)
            }
            return nil
        default:
            return nil
        }
    }
}
