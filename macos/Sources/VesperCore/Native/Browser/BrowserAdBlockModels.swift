import Foundation

// MARK: - Ad-Block Categories & Subscriptions

public enum BrowserAdBlockCategory: String, Codable, Sendable, CaseIterable, Identifiable, Hashable {
    case ads
    case trackers
    case annoyances
    case scriptlets

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .ads: return "Ads"
        case .trackers: return "Trackers & Privacy"
        case .annoyances: return "Cookie Banners & Annoyances"
        case .scriptlets: return "Scriptlets & Extended CSS"
        }
    }

    public var summary: String {
        switch self {
        case .ads: return "Ad networks, programmatic exchanges, video ads, and ad containers"
        case .trackers: return "Analytics, session replay, fingerprinting, and tracking pixels"
        case .annoyances: return "GDPR/cookie overlays, scroll locks, and push/app nags"
        case .scriptlets: return "YouTube stripping, anti-adblock defusers, and procedural hiding"
        }
    }

    public var icon: String {
        switch self {
        case .ads: return "nosign"
        case .trackers: return "eye.slash"
        case .annoyances: return "hand.raised"
        case .scriptlets: return "bolt.shield"
        }
    }

    public var bundledFilename: String {
        switch self {
        case .ads: return "ads.txt"
        case .trackers: return "trackers.txt"
        case .annoyances: return "annoyances.txt"
        case .scriptlets: return "scriptlets.txt"
        }
    }
}

public struct BrowserFilterListSubscription: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var category: BrowserAdBlockCategory
    public var url: String
    public var isBuiltIn: Bool
    public var isEnabled: Bool
    public var lastUpdatedAt: Date?
    public var ruleCount: Int
    public var lastError: String?

    public init(
        id: String = UUID().uuidString.lowercased(),
        name: String,
        category: BrowserAdBlockCategory,
        url: String,
        isBuiltIn: Bool = false,
        isEnabled: Bool = true,
        lastUpdatedAt: Date? = nil,
        ruleCount: Int = 0,
        lastError: String? = nil
    ) {
        self.id = id
        self.name = name
        self.category = category
        self.url = url
        self.isBuiltIn = isBuiltIn
        self.isEnabled = isEnabled
        self.lastUpdatedAt = lastUpdatedAt
        self.ruleCount = ruleCount
        self.lastError = lastError
    }

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case category
        case url
        case isBuiltIn = "is_built_in"
        case isEnabled = "is_enabled"
        case lastUpdatedAt = "last_updated_at"
        case ruleCount = "rule_count"
        case lastError = "last_error"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString.lowercased()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Filter List"
        category = try c.decodeIfPresent(BrowserAdBlockCategory.self, forKey: .category) ?? .ads
        url = try c.decodeIfPresent(String.self, forKey: .url) ?? ""
        isBuiltIn = try c.decodeIfPresent(Bool.self, forKey: .isBuiltIn) ?? false
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        lastUpdatedAt = try c.decodeIfPresent(Date.self, forKey: .lastUpdatedAt)
        ruleCount = try c.decodeIfPresent(Int.self, forKey: .ruleCount) ?? 0
        lastError = try c.decodeIfPresent(String.self, forKey: .lastError)
    }

    /// Authoritative upstream EasyList / EasyPrivacy / Peter Lowe / Fanboy / uBlock subscriptions.
    public static let defaultBuiltIns: [BrowserFilterListSubscription] = [
        BrowserFilterListSubscription(
            id: "easylist",
            name: "EasyList",
            category: .ads,
            url: "https://easylist.to/easylist/easylist.txt",
            isBuiltIn: true,
            isEnabled: true
        ),
        BrowserFilterListSubscription(
            id: "peter-lowe",
            name: "Peter Lowe's Ad & Tracking List",
            category: .ads,
            url: "https://pgl.yoyo.org/adservers/serverlist.php?hostformat=adblockplus&showintro=0&mimetype=plaintext",
            isBuiltIn: true,
            isEnabled: true
        ),
        BrowserFilterListSubscription(
            id: "easyprivacy",
            name: "EasyPrivacy",
            category: .trackers,
            url: "https://easylist.to/easylist/easyprivacy.txt",
            isBuiltIn: true,
            isEnabled: true
        ),
        BrowserFilterListSubscription(
            id: "fanboy-annoyances",
            name: "Fanboy's Annoyance & Cookie List",
            category: .annoyances,
            url: "https://secure.fanboy.co.nz/fanboy-annoyance.txt",
            isBuiltIn: true,
            isEnabled: true
        ),
        BrowserFilterListSubscription(
            id: "ublock-filters",
            name: "uBlock Origin Filters & Scriptlets",
            category: .scriptlets,
            url: "https://ublockorigin.github.io/uAssets/filters/filters.min.txt",
            isBuiltIn: true,
            isEnabled: true
        ),
        BrowserFilterListSubscription(
            id: "ublock-quick-fixes",
            name: "uBlock Quick Fixes (YouTube & Breakage)",
            category: .scriptlets,
            url: "https://ublockorigin.github.io/uAssets/filters/quick-fixes.txt",
            isBuiltIn: true,
            isEnabled: true
        ),
    ]
}

public struct BrowserAdBlockConfig: Codable, Sendable, Equatable {
    public var enabledCategories: [BrowserAdBlockCategory]
    public var subscriptions: [BrowserFilterListSubscription]
    public var customRules: String
    public var youtubeAdShieldEnabled: Bool
    public var autoUpdateEnabled: Bool
    public var lastUpdatedAt: Date?

    public init(
        enabledCategories: [BrowserAdBlockCategory] = BrowserAdBlockCategory.allCases,
        subscriptions: [BrowserFilterListSubscription] = BrowserFilterListSubscription.defaultBuiltIns,
        customRules: String = "",
        youtubeAdShieldEnabled: Bool = true,
        autoUpdateEnabled: Bool = true,
        lastUpdatedAt: Date? = nil
    ) {
        self.enabledCategories = enabledCategories
        self.subscriptions = subscriptions
        self.customRules = customRules
        self.youtubeAdShieldEnabled = youtubeAdShieldEnabled
        self.autoUpdateEnabled = autoUpdateEnabled
        self.lastUpdatedAt = lastUpdatedAt
    }

    public static let `default` = BrowserAdBlockConfig()

    public func isCategoryEnabled(_ category: BrowserAdBlockCategory) -> Bool {
        enabledCategories.contains(category)
    }

    public mutating func setCategory(_ category: BrowserAdBlockCategory, enabled: Bool) {
        if enabled {
            if !enabledCategories.contains(category) {
                enabledCategories.append(category)
            }
        } else {
            enabledCategories.removeAll { $0 == category }
        }
    }

    enum CodingKeys: String, CodingKey {
        case enabledCategories = "enabled_categories"
        case subscriptions
        case customRules = "custom_rules"
        case youtubeAdShieldEnabled = "youtube_ad_shield_enabled"
        case autoUpdateEnabled = "auto_update_enabled"
        case lastUpdatedAt = "last_updated_at"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabledCategories = try c.decodeIfPresent([BrowserAdBlockCategory].self, forKey: .enabledCategories) ?? BrowserAdBlockCategory.allCases
        let decodedSubs = try c.decodeIfPresent([BrowserFilterListSubscription].self, forKey: .subscriptions) ?? []
        if decodedSubs.isEmpty {
            subscriptions = BrowserFilterListSubscription.defaultBuiltIns
        } else {
            // Merge any newly added built-ins while preserving user toggle state and custom lists.
            var merged = decodedSubs
            for builtin in BrowserFilterListSubscription.defaultBuiltIns where !merged.contains(where: { $0.id == builtin.id }) {
                merged.append(builtin)
            }
            subscriptions = merged
        }
        customRules = try c.decodeIfPresent(String.self, forKey: .customRules) ?? ""
        youtubeAdShieldEnabled = try c.decodeIfPresent(Bool.self, forKey: .youtubeAdShieldEnabled) ?? true
        autoUpdateEnabled = try c.decodeIfPresent(Bool.self, forKey: .autoUpdateEnabled) ?? true
        lastUpdatedAt = try c.decodeIfPresent(Date.self, forKey: .lastUpdatedAt)
    }

    /// Validates a user-supplied custom filter list URL (strictly HTTPS only to prevent local file/SSRF reads).
    public static func validateSubscriptionURL(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let url = URL(string: trimmed),
              url.scheme?.lowercased() == "https",
              let host = url.host,
              !host.isEmpty
        else { return nil }
        return url
    }
}

// MARK: - Bundled Starter List Loader

public enum BrowserAdBlockBundle {
    /// Loads the offline starter filter list text shipped inside `VesperCore/Resources/adblock/`.
    /// Mirrors `CodeHighlighter.bundledScript()` so it works across SwiftPM test runs and packaged `Vesper.app`.
    public static func bundledListText(for category: BrowserAdBlockCategory) -> String {
        guard let url = bundledListURL(for: category),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else { return "" }
        return text
    }

    public static func bundledListURL(for category: BrowserAdBlockCategory) -> URL? {
        let filename = category.bundledFilename
        let stem = (filename as NSString).deletingPathExtension
        let ext = (filename as NSString).pathExtension
        let bundleName = "Vesper_VesperCore.bundle"

        var dirs: [URL] = [
            Bundle.main.resourceURL,
            Bundle.main.bundleURL,
            Bundle.main.executableURL?.deletingLastPathComponent(),
        ].compactMap { $0 }
        dirs += Bundle.allBundles.map { $0.bundleURL.deletingLastPathComponent() }

        for dir in dirs {
            let bundleURL = dir.appendingPathComponent(bundleName)
            if let bundle = Bundle(url: bundleURL) {
                if let url = bundle.url(forResource: stem, withExtension: ext, subdirectory: "adblock") {
                    return url
                }
                if let url = bundle.url(forResource: stem, withExtension: ext) {
                    return url
                }
            }
            let candidates = [
                bundleURL.appendingPathComponent("adblock/\(filename)"),
                bundleURL.appendingPathComponent("Contents/Resources/adblock/\(filename)"),
            ]
            for candidate in candidates where FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        if let url = Bundle.module.url(forResource: stem, withExtension: ext, subdirectory: "adblock") {
            return url
        }
        return nil
    }
}
