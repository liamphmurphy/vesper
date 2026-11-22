import Foundation

/// Status pill representation for a registered media provider.
public struct MediaProviderStatus: Sendable, Equatable {
    public let tone: SettingsBadgeTone
    public let label: String

    public init(tone: SettingsBadgeTone, label: String) {
        self.tone = tone
        self.label = label
    }
}

/// Active-engine overview for one media capability (music, video, tts, ...).
public struct MediaCapabilityGroup: Sendable, Equatable, Identifiable {
    public let capability: API.MediaCapability
    public let label: String
    public let providers: [API.MediaProvider]
    public let active: API.MediaProvider?
    public let selectedId: String?

    public var id: String { capability.rawValue }

    public init(
        capability: API.MediaCapability,
        label: String,
        providers: [API.MediaProvider],
        active: API.MediaProvider?,
        selectedId: String?
    ) {
        self.capability = capability
        self.label = label
        self.providers = providers
        self.active = active
        self.selectedId = selectedId
    }
}

/// Pure helpers for schema-driven media provider settings (Swift counterpart of `web/lib/media-providers.ts`).
public enum MediaProviderHelpers {
    /// Human-readable label for a capability pill or heading.
    public static func capabilityLabel(_ cap: API.MediaCapability) -> String {
        switch cap {
        case .music: return "Music"
        case .video: return "Video"
        case .tts: return "Voice (TTS)"
        case .script: return "Podcast script"
        default: return cap.rawValue
        }
    }

    /// Short pill label shown on provider cards.
    public static func capabilityPillLabel(_ cap: API.MediaCapability) -> String {
        switch cap {
        case .music: return "Music"
        case .video: return "Video"
        case .tts: return "TTS"
        case .script: return "Script"
        default: return cap.rawValue
        }
    }

    /// Merges field defaults, saved settings, and unsaved draft edits for non-secret fields.
    public static func effectiveSettings(
        for provider: API.MediaProvider,
        draftSettings: [String: String] = [:]
    ) -> [String: String] {
        var out: [String: String] = [:]
        for field in provider.fields {
            if field.kind == .secret { continue }
            if let def = field.default, !def.isEmpty {
                out[field.key] = def
            }
        }
        for (k, v) in provider.settings {
            out[k] = v
        }
        for (k, v) in draftSettings {
            out[k] = v
        }
        return out
    }

    /// True when every condition in `field.showWhen` matches the effective setting value.
    public static func isFieldVisible(_ field: API.MediaFieldSpec, settings: [String: String]) -> Bool {
        guard let conditions = field.showWhen, !conditions.isEmpty else { return true }
        for (key, expected) in conditions {
            if (settings[key] ?? "") != expected {
                return false
            }
        }
        return true
    }

    /// Visible fields in descriptor order for the given effective settings.
    public static func visibleFields(
        for provider: API.MediaProvider,
        settings: [String: String]
    ) -> [API.MediaFieldSpec] {
        provider.fields.filter { isFieldVisible($0, settings: settings) }
    }

    /// All providers advertising `capability`, in server registration order.
    public static func providers(
        for capability: API.MediaCapability,
        in data: API.MediaProvidersResponse?
    ) -> [API.MediaProvider] {
        guard let data else { return [] }
        return data.providers.filter { $0.capabilities.contains(capability) }
    }

    /// Resolved active provider for `capability`: workspace default when ready, else first available enabled provider.
    public static func activeProvider(
        for capability: API.MediaCapability,
        in data: API.MediaProvidersResponse?
    ) -> API.MediaProvider? {
        let list = providers(for: capability, in: data)
        if let defId = data?.defaults[capability.rawValue], !defId.isEmpty,
           let chosen = list.first(where: { $0.id == defId && $0.available && $0.enabled && !$0.comingSoon })
        {
            return chosen
        }
        return list.first(where: { $0.available && $0.enabled && !$0.comingSoon })
    }

    /// Capability groups in display order for every capability with at least one registered provider.
    public static func capabilityGroups(in data: API.MediaProvidersResponse?) -> [MediaCapabilityGroup] {
        guard let data else { return [] }
        var seen = Set<String>()
        var ordered: [API.MediaCapability] = []
        for cap in API.MediaCapability.allKnown {
            if seen.insert(cap.rawValue).inserted {
                ordered.append(cap)
            }
        }
        for provider in data.providers {
            for cap in provider.capabilities where seen.insert(cap.rawValue).inserted {
                ordered.append(cap)
            }
        }
        return ordered.compactMap { cap in
            let list = providers(for: cap, in: data)
            guard !list.isEmpty else { return nil }
            let active = activeProvider(for: cap, in: data)
            let explicit = data.defaults[cap.rawValue]
            let selectedId = (explicit?.isEmpty == false ? explicit : nil) ?? active?.id
            return MediaCapabilityGroup(
                capability: cap,
                label: capabilityLabel(cap),
                providers: list,
                active: active,
                selectedId: selectedId
            )
        }
    }

    /// Status badge tone and label for a provider card.
    public static func providerStatus(_ provider: API.MediaProvider) -> MediaProviderStatus {
        if provider.comingSoon {
            return MediaProviderStatus(tone: .neutral, label: "Coming soon")
        }
        if !provider.enabled {
            return MediaProviderStatus(tone: .neutral, label: "Disabled")
        }
        if provider.available {
            return MediaProviderStatus(tone: .done, label: "Connected")
        }
        return MediaProviderStatus(tone: .human, label: "Not configured")
    }

    /// True when any non-secret effective value differs from the saved config or any secret draft has non-whitespace input.
    public static func hasDirtyChanges(
        for provider: API.MediaProvider,
        draftSettings: [String: String],
        draftSecrets: [String: String]
    ) -> Bool {
        if draftSecrets.values.contains(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            return true
        }
        if draftSettings.isEmpty { return false }
        let saved = effectiveSettings(for: provider)
        let current = effectiveSettings(for: provider, draftSettings: draftSettings)
        for field in provider.fields where field.kind != .secret {
            if (current[field.key] ?? "") != (saved[field.key] ?? "") {
                return true
            }
        }
        return false
    }

    /// Builds a `PUT /media/providers/{id}` payload, omitting `secrets` when no secret draft is non-empty.
    public static func buildProviderPatch(
        for provider: API.MediaProvider,
        draftSettings: [String: String],
        draftSecrets: [String: String]
    ) -> API.UpdateMediaProviderRequest {
        let merged = effectiveSettings(for: provider, draftSettings: draftSettings)
        var settings: [String: String] = [:]
        for field in provider.fields where field.kind != .secret {
            if let val = merged[field.key] {
                settings[field.key] = val
            }
        }
        var secrets: [String: String] = [:]
        for field in provider.fields where field.kind == .secret {
            let trimmed = (draftSecrets[field.key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                secrets[field.key] = trimmed
            }
        }
        return API.UpdateMediaProviderRequest(
            secrets: secrets.isEmpty ? nil : secrets,
            settings: settings
        )
    }
}
