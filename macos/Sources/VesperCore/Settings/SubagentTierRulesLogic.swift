import Foundation

/// Pure logic for automatic subagent tier routing and per-harness Deep / Standard / Fast model ladders.
public enum SubagentTierRulesLogic {
    public struct HarnessSpec: Sendable, Equatable, Identifiable {
        public let id: String
        public let label: String
        public init(id: String, label: String) {
            self.id = id
            self.label = label
        }
    }

    public enum TierKey: String, CaseIterable, Sendable, Identifiable {
        case deep
        case standard
        case fast

        public var id: String { rawValue }
        public var label: String {
            switch self {
            case .deep: "Deep"
            case .standard: "Standard"
            case .fast: "Fast"
            }
        }
    }

    public static let harnesses: [HarnessSpec] = [
        HarnessSpec(id: "claude-code", label: "Claude Code"),
        HarnessSpec(id: "codex", label: "Codex"),
        HarnessSpec(id: "antigravity", label: "Antigravity"),
    ]

    /// Filters out orchestrator wrapper entries when choosing subagent target models.
    public static func selectableModels(_ models: [API.ChatModel]?) -> [API.ChatModel] {
        guard let models, !models.isEmpty else { return [] }
        return models.filter { model in
            let combined = "\(model.id) \(model.label)"
            return combined.range(of: #"\borchestrator\b"#, options: [.regularExpression, .caseInsensitive]) == nil
        }
    }

    /// True when a configured model ID is no longer present in a loaded non-empty live catalog.
    public static func isStaleModel(_ modelId: String?, catalog: [API.ChatModel]?) -> Bool {
        guard let needle = modelId?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !needle.isEmpty,
              let catalog, !catalog.isEmpty else {
            return false
        }
        return !catalog.contains { $0.id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == needle }
    }

    public static func model(for tier: TierKey, in entry: API.SubagentTierModels?) -> String {
        switch tier {
        case .deep: entry?.deep ?? ""
        case .standard: entry?.standard ?? ""
        case .fast: entry?.fast ?? ""
        }
    }

    public static func hasCustomRules(_ entry: API.SubagentTierModels?) -> Bool {
        guard let entry else { return false }
        let values = [entry.deep, entry.standard, entry.fast]
        return values.contains { ($0?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false) }
    }

    private static func cleaned(_ entry: API.SubagentTierModels?) -> API.SubagentTierModels? {
        guard let entry else { return nil }
        let fast = entry.fast?.trimmingCharacters(in: .whitespacesAndNewlines)
        let standard = entry.standard?.trimmingCharacters(in: .whitespacesAndNewlines)
        let deep = entry.deep?.trimmingCharacters(in: .whitespacesAndNewlines)
        let f = (fast?.isEmpty == false) ? fast : nil
        let s = (standard?.isEmpty == false) ? standard : nil
        let d = (deep?.isEmpty == false) ? deep : nil
        guard f != nil || s != nil || d != nil else { return nil }
        return API.SubagentTierModels(deep: d, fast: f, standard: s)
    }

    /// Returns an updated rules map with empty strings trimmed and empty harness entries removed.
    public static func settingModel(
        in rules: [String: API.SubagentTierModels]?,
        harness: String,
        tier: TierKey,
        modelId: String
    ) -> [String: API.SubagentTierModels] {
        var next: [String: API.SubagentTierModels] = [:]
        for (key, entry) in rules ?? [:] where key != harness {
            if let clean = cleaned(entry) {
                next[key] = clean
            }
        }
        var current = rules?[harness] ?? API.SubagentTierModels()
        switch tier {
        case .deep: current.deep = modelId
        case .standard: current.standard = modelId
        case .fast: current.fast = modelId
        }
        if let clean = cleaned(current) {
            next[harness] = clean
        }
        return next
    }

    /// Returns an updated rules map with the given harness rule removed.
    public static func clearingHarness(
        in rules: [String: API.SubagentTierModels]?,
        harness: String
    ) -> [String: API.SubagentTierModels] {
        var next: [String: API.SubagentTierModels] = [:]
        for (key, entry) in rules ?? [:] where key != harness {
            if let clean = cleaned(entry) {
                next[key] = clean
            }
        }
        return next
    }
}
