import Foundation

// MARK: - Search Engines

public enum BrowserSearchEngine: String, Codable, Sendable, CaseIterable, Hashable, Identifiable {
    case duckDuckGo = "duckduckgo"
    case kagi = "kagi"
    case brave = "brave"
    case google = "google"

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .duckDuckGo: "DuckDuckGo"
        case .kagi: "Kagi"
        case .brave: "Brave Search"
        case .google: "Google"
        }
    }

    public func searchURL(for query: String) -> URL? {
        var comps = URLComponents()
        comps.scheme = "https"
        switch self {
        case .duckDuckGo:
            comps.host = "duckduckgo.com"
            comps.path = "/"
            comps.queryItems = [URLQueryItem(name: "q", value: query)]
        case .kagi:
            comps.host = "kagi.com"
            comps.path = "/search"
            comps.queryItems = [URLQueryItem(name: "q", value: query)]
        case .brave:
            comps.host = "search.brave.com"
            comps.path = "/search"
            comps.queryItems = [URLQueryItem(name: "q", value: query)]
        case .google:
            comps.host = "www.google.com"
            comps.path = "/search"
            comps.queryItems = [URLQueryItem(name: "q", value: query)]
        }
        return comps.url
    }
}

// MARK: - Profiles, Tab Groups & Extensions

public enum BrowserProfileColor: String, Codable, Sendable, CaseIterable, Hashable, Identifiable {
    case blue
    case purple
    case green
    case orange
    case pink
    case teal
    case indigo
    case gray

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .blue: "Blue"
        case .purple: "Purple"
        case .green: "Green"
        case .orange: "Orange"
        case .pink: "Pink"
        case .teal: "Teal"
        case .indigo: "Indigo"
        case .gray: "Gray"
        }
    }
}

public struct BrowserTabGroup: Codable, Sendable, Equatable, Hashable, Identifiable {
    public var id: UUID
    public var name: String
    public var color: BrowserProfileColor
    public var isCollapsed: Bool
    /// Optional Vesper Space ID bound to this tab group for smart clip & persona routing.
    public var spaceId: String?

    public init(
        id: UUID = UUID(),
        name: String,
        color: BrowserProfileColor = .blue,
        isCollapsed: Bool = false,
        spaceId: String? = nil
    ) {
        self.id = id
        self.name = name
        self.color = color
        self.isCollapsed = isCollapsed
        self.spaceId = spaceId
    }

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case color
        case isCollapsed = "is_collapsed"
        case spaceId = "space_id"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Group"
        color = try c.decodeIfPresent(BrowserProfileColor.self, forKey: .color) ?? .blue
        isCollapsed = try c.decodeIfPresent(Bool.self, forKey: .isCollapsed) ?? false
        spaceId = try c.decodeIfPresent(String.self, forKey: .spaceId)
    }
}

public struct BrowserExtensionRecord: Codable, Sendable, Equatable, Hashable, Identifiable {
    public var id: UUID
    public var displayName: String
    public var identifier: String
    public var sourcePath: String
    public var isEnabled: Bool
    public var isManagedCopy: Bool
    public var allowInPrivate: Bool
    public var grantAllHosts: Bool
    public var installedAt: Date

    public init(
        id: UUID = UUID(),
        displayName: String,
        identifier: String? = nil,
        sourcePath: String,
        isEnabled: Bool = true,
        isManagedCopy: Bool = false,
        allowInPrivate: Bool = false,
        grantAllHosts: Bool = false,
        installedAt: Date = Date()
    ) {
        self.id = id
        self.displayName = displayName
        self.identifier = identifier ?? id.uuidString.lowercased()
        self.sourcePath = sourcePath
        self.isEnabled = isEnabled
        self.isManagedCopy = isManagedCopy
        self.allowInPrivate = allowInPrivate
        self.grantAllHosts = grantAllHosts
        self.installedAt = installedAt
    }

    enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
        case identifier
        case sourcePath = "source_path"
        case isEnabled = "is_enabled"
        case isManagedCopy = "is_managed_copy"
        case allowInPrivate = "allow_in_private"
        case grantAllHosts = "grant_all_hosts"
        case installedAt = "installed_at"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let decodedID = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        id = decodedID
        displayName = try c.decodeIfPresent(String.self, forKey: .displayName) ?? "Extension"
        identifier = try c.decodeIfPresent(String.self, forKey: .identifier) ?? decodedID.uuidString.lowercased()
        sourcePath = try c.decodeIfPresent(String.self, forKey: .sourcePath) ?? ""
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        isManagedCopy = try c.decodeIfPresent(Bool.self, forKey: .isManagedCopy) ?? false
        allowInPrivate = try c.decodeIfPresent(Bool.self, forKey: .allowInPrivate) ?? false
        grantAllHosts = try c.decodeIfPresent(Bool.self, forKey: .grantAllHosts) ?? false
        installedAt = try c.decodeIfPresent(Date.self, forKey: .installedAt) ?? Date()
    }
}

// MARK: - Persisted Browser Records

public struct BrowserTabRecord: Codable, Sendable, Equatable, Hashable, Identifiable {
    public var id: UUID
    public var url: String
    public var title: String
    public var isPinned: Bool
    public var isPrivate: Bool
    public var zoom: Double
    public var groupId: UUID?
    public var isMuted: Bool

    public init(
        id: UUID = UUID(),
        url: String = "",
        title: String = "New Tab",
        isPinned: Bool = false,
        isPrivate: Bool = false,
        zoom: Double = 1.0,
        groupId: UUID? = nil,
        isMuted: Bool = false
    ) {
        self.id = id
        self.url = url
        self.title = title
        self.isPinned = isPinned
        self.isPrivate = isPrivate
        self.zoom = zoom
        self.groupId = groupId
        self.isMuted = isMuted
    }

    enum CodingKeys: String, CodingKey {
        case id
        case url
        case title
        case isPinned
        case isPrivate
        case zoom
        case groupId = "group_id"
        case isMuted = "is_muted"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        url = try c.decodeIfPresent(String.self, forKey: .url) ?? ""
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? "New Tab"
        isPinned = try c.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
        isPrivate = try c.decodeIfPresent(Bool.self, forKey: .isPrivate) ?? false
        zoom = try c.decodeIfPresent(Double.self, forKey: .zoom) ?? 1.0
        groupId = try c.decodeIfPresent(UUID.self, forKey: .groupId)
        isMuted = try c.decodeIfPresent(Bool.self, forKey: .isMuted) ?? false
    }
}

public struct BrowserBookmark: Codable, Sendable, Equatable, Hashable, Identifiable {
    public var id: String
    public var url: String
    public var title: String
    public var folder: String?
    public var createdAt: Date

    public init(
        id: String = UUID().uuidString.lowercased(),
        url: String,
        title: String,
        folder: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.url = url
        self.title = title
        self.folder = folder
        self.createdAt = createdAt
    }
}

public struct BrowserHistoryEntry: Codable, Sendable, Equatable, Hashable, Identifiable {
    public var id: String
    public var url: String
    public var title: String
    public var visitedAt: Date
    public var visitCount: Int

    public init(
        id: String = UUID().uuidString.lowercased(),
        url: String,
        title: String,
        visitedAt: Date = Date(),
        visitCount: Int = 1
    ) {
        self.id = id
        self.url = url
        self.title = title
        self.visitedAt = visitedAt
        self.visitCount = visitCount
    }
}

public struct BrowserProfile: Codable, Sendable, Equatable, Hashable, Identifiable {
    /// Stable data store UUID matching Tier 1's `BrowserWebViewFactory.browsingStoreID`, so
    /// upgrading from Tier 1 preserves existing cookies and site sessions in the default profile.
    public static let defaultDataStoreID = UUID(uuidString: "9E6F2D4A-8B7C-4D3E-A1F2-5C8B9E0A4F11")!
    public static let defaultProfileID = UUID(uuidString: "B7C1E9D0-4A32-4F8B-9C1E-2D5A8F6B3E01")!

    public var id: UUID
    public var name: String
    public var icon: String
    public var color: BrowserProfileColor
    public var dataStoreID: UUID
    public var tabs: [BrowserTabRecord]
    public var activeTabId: UUID?
    public var splitTabId: UUID?
    public var splitRatio: Double
    public var tabGroups: [BrowserTabGroup]
    public var bookmarks: [BrowserBookmark]
    public var history: [BrowserHistoryEntry]
    public var adBlockDisabledHosts: [String]
    public var siteZooms: [String: Double]
    public var extensions: [BrowserExtensionRecord]
    public var autofillNeverSaveHosts: [String]
    public var httpsOnlyExceptions: [String]
    public var lockdownEnabledHosts: [String]
    public var lockdownDisabledHosts: [String]
    public var javascriptDisabledHosts: [String]
    public var sitePermissions: [String: [String: BrowserPermissionSetting]]
    public var proxyConfig: BrowserProxyConfig
    /// Optional Vesper Space ID bound to this entire profile (overridden by Tab Group binding).
    public var spaceId: String?
    /// Persistent web highlights stored per profile and synced to Knowledge notes.
    public var highlights: [BrowserWebHighlight]
    /// Per-site Auto Dark Mode overrides (`.on` forces dark mode, `.off` disables it).
    public var darkModeSiteOverrides: [String: BrowserDarkModeSiteOverride]

    public init(
        id: UUID = UUID(),
        name: String,
        icon: String = "person.crop.circle",
        color: BrowserProfileColor = .blue,
        dataStoreID: UUID = UUID(),
        tabs: [BrowserTabRecord] = [],
        activeTabId: UUID? = nil,
        splitTabId: UUID? = nil,
        splitRatio: Double = 0.5,
        tabGroups: [BrowserTabGroup] = [],
        bookmarks: [BrowserBookmark] = [],
        history: [BrowserHistoryEntry] = [],
        adBlockDisabledHosts: [String] = [],
        siteZooms: [String: Double] = [:],
        extensions: [BrowserExtensionRecord] = [],
        autofillNeverSaveHosts: [String] = [],
        httpsOnlyExceptions: [String] = [],
        lockdownEnabledHosts: [String] = [],
        lockdownDisabledHosts: [String] = [],
        javascriptDisabledHosts: [String] = [],
        sitePermissions: [String: [String: BrowserPermissionSetting]] = [:],
        proxyConfig: BrowserProxyConfig = .none,
        spaceId: String? = nil,
        highlights: [BrowserWebHighlight] = [],
        darkModeSiteOverrides: [String: BrowserDarkModeSiteOverride] = [:]
    ) {
        self.id = id
        self.name = name
        self.icon = icon
        self.color = color
        self.dataStoreID = dataStoreID
        self.tabs = tabs
        self.activeTabId = activeTabId
        self.splitTabId = splitTabId
        self.splitRatio = splitRatio
        self.tabGroups = tabGroups
        self.bookmarks = bookmarks
        self.history = history
        self.adBlockDisabledHosts = adBlockDisabledHosts
        self.siteZooms = siteZooms
        self.extensions = extensions
        self.autofillNeverSaveHosts = autofillNeverSaveHosts
        self.httpsOnlyExceptions = httpsOnlyExceptions
        self.lockdownEnabledHosts = lockdownEnabledHosts
        self.lockdownDisabledHosts = lockdownDisabledHosts
        self.javascriptDisabledHosts = javascriptDisabledHosts
        self.sitePermissions = sitePermissions
        self.proxyConfig = proxyConfig
        self.spaceId = spaceId
        self.highlights = highlights
        self.darkModeSiteOverrides = darkModeSiteOverrides
    }

    public static func defaultPersonal(
        tabs: [BrowserTabRecord] = [],
        activeTabId: UUID? = nil,
        bookmarks: [BrowserBookmark] = [],
        history: [BrowserHistoryEntry] = [],
        adBlockDisabledHosts: [String] = [],
        siteZooms: [String: Double] = [:]
    ) -> BrowserProfile {
        BrowserProfile(
            id: defaultProfileID,
            name: "Personal",
            icon: "person.crop.circle",
            color: .blue,
            dataStoreID: defaultDataStoreID,
            tabs: tabs,
            activeTabId: activeTabId,
            bookmarks: bookmarks,
            history: history,
            adBlockDisabledHosts: adBlockDisabledHosts,
            siteZooms: siteZooms
        )
    }

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case icon
        case color
        case dataStoreID = "data_store_id"
        case tabs
        case activeTabId = "active_tab_id"
        case splitTabId = "split_tab_id"
        case splitRatio = "split_ratio"
        case tabGroups = "tab_groups"
        case bookmarks
        case history
        case adBlockDisabledHosts = "ad_block_disabled_hosts"
        case siteZooms = "site_zooms"
        case extensions
        case autofillNeverSaveHosts = "autofill_never_save_hosts"
        case httpsOnlyExceptions = "https_only_exceptions"
        case lockdownEnabledHosts = "lockdown_enabled_hosts"
        case lockdownDisabledHosts = "lockdown_disabled_hosts"
        case javascriptDisabledHosts = "javascript_disabled_hosts"
        case sitePermissions = "site_permissions"
        case proxyConfig = "proxy_config"
        case spaceId = "space_id"
        case highlights
        case darkModeSiteOverrides = "dark_mode_site_overrides"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Profile"
        icon = try c.decodeIfPresent(String.self, forKey: .icon) ?? "person.crop.circle"
        color = try c.decodeIfPresent(BrowserProfileColor.self, forKey: .color) ?? .blue
        dataStoreID = try c.decodeIfPresent(UUID.self, forKey: .dataStoreID) ?? UUID()
        tabs = try c.decodeIfPresent([BrowserTabRecord].self, forKey: .tabs) ?? []
        activeTabId = try c.decodeIfPresent(UUID.self, forKey: .activeTabId)
        splitTabId = try c.decodeIfPresent(UUID.self, forKey: .splitTabId)
        splitRatio = min(0.8, max(0.2, try c.decodeIfPresent(Double.self, forKey: .splitRatio) ?? 0.5))
        tabGroups = try c.decodeIfPresent([BrowserTabGroup].self, forKey: .tabGroups) ?? []
        bookmarks = try c.decodeIfPresent([BrowserBookmark].self, forKey: .bookmarks) ?? []
        history = try c.decodeIfPresent([BrowserHistoryEntry].self, forKey: .history) ?? []
        adBlockDisabledHosts = try c.decodeIfPresent([String].self, forKey: .adBlockDisabledHosts) ?? []
        siteZooms = try c.decodeIfPresent([String: Double].self, forKey: .siteZooms) ?? [:]
        extensions = try c.decodeIfPresent([BrowserExtensionRecord].self, forKey: .extensions) ?? []
        autofillNeverSaveHosts = try c.decodeIfPresent([String].self, forKey: .autofillNeverSaveHosts) ?? []
        httpsOnlyExceptions = try c.decodeIfPresent([String].self, forKey: .httpsOnlyExceptions) ?? []
        lockdownEnabledHosts = try c.decodeIfPresent([String].self, forKey: .lockdownEnabledHosts) ?? []
        lockdownDisabledHosts = try c.decodeIfPresent([String].self, forKey: .lockdownDisabledHosts) ?? []
        javascriptDisabledHosts = try c.decodeIfPresent([String].self, forKey: .javascriptDisabledHosts) ?? []
        sitePermissions = try c.decodeIfPresent([String: [String: BrowserPermissionSetting]].self, forKey: .sitePermissions) ?? [:]
        proxyConfig = try c.decodeIfPresent(BrowserProxyConfig.self, forKey: .proxyConfig) ?? .none
        spaceId = try c.decodeIfPresent(String.self, forKey: .spaceId)
        highlights = try c.decodeIfPresent([BrowserWebHighlight].self, forKey: .highlights) ?? []
        darkModeSiteOverrides = try c.decodeIfPresent([String: BrowserDarkModeSiteOverride].self, forKey: .darkModeSiteOverrides) ?? [:]
    }
}

public struct BrowserLayoutConfig: Codable, Sendable, Equatable, Hashable {
    public static let minZoom: Double = 0.5
    public static let maxZoom: Double = 2.0
    public static let presetZooms: [Double] = [0.75, 0.85, 0.90, 1.0, 1.10, 1.25, 1.50]

    public var autoHideOmnibox: Bool
    public var hoverPeekSidebar: Bool
    public var defaultZoom: Double
    /// When enabled, automatically pushes the active non-private, shareable tab to Companion Chat.
    public var autoFollowCompanionTab: Bool

    public static let `default` = BrowserLayoutConfig()

    public init(
        autoHideOmnibox: Bool = false,
        hoverPeekSidebar: Bool = true,
        defaultZoom: Double = 1.0,
        autoFollowCompanionTab: Bool = false
    ) {
        self.autoHideOmnibox = autoHideOmnibox
        self.hoverPeekSidebar = hoverPeekSidebar
        self.defaultZoom = Self.clampZoom(defaultZoom)
        self.autoFollowCompanionTab = autoFollowCompanionTab
    }

    public static func clampZoom(_ value: Double) -> Double {
        guard value.isFinite else { return 1.0 }
        let clamped = min(maxZoom, max(minZoom, value))
        return (clamped * 100).rounded() / 100
    }

    public func effectiveZoom(for host: String?, siteZooms: [String: Double]) -> Double {
        if let host, !host.isEmpty, let site = siteZooms[host.lowercased()] {
            return min(3.0, max(0.3, site))
        }
        return Self.clampZoom(defaultZoom)
    }

    enum CodingKeys: String, CodingKey {
        case autoHideOmnibox = "auto_hide_omnibox"
        case hoverPeekSidebar = "hover_peek_sidebar"
        case defaultZoom = "default_zoom"
        case autoFollowCompanionTab = "auto_follow_companion_tab"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        autoHideOmnibox = try c.decodeIfPresent(Bool.self, forKey: .autoHideOmnibox) ?? false
        hoverPeekSidebar = try c.decodeIfPresent(Bool.self, forKey: .hoverPeekSidebar) ?? true
        defaultZoom = Self.clampZoom(try c.decodeIfPresent(Double.self, forKey: .defaultZoom) ?? 1.0)
        autoFollowCompanionTab = try c.decodeIfPresent(Bool.self, forKey: .autoFollowCompanionTab) ?? false
    }
}

public struct BrowserPersistedState: Codable, Sendable, Equatable {
    public var tabs: [BrowserTabRecord]
    public var activeTabId: UUID?
    public var bookmarks: [BrowserBookmark]
    public var history: [BrowserHistoryEntry]
    public var adBlockEnabled: Bool
    public var adBlockDisabledHosts: [String]
    public var openExternalLinksInBrowser: Bool
    public var searchEngine: BrowserSearchEngine
    public var siteZooms: [String: Double]
    public var profiles: [BrowserProfile]
    public var activeProfileId: UUID?
    public var autofillEnabled: Bool
    public var adBlockConfig: BrowserAdBlockConfig
    public var securityConfig: BrowserSecurityConfig
    public var layoutConfig: BrowserLayoutConfig
    public var darkModeConfig: BrowserDarkModeConfig

    public init(
        tabs: [BrowserTabRecord] = [],
        activeTabId: UUID? = nil,
        bookmarks: [BrowserBookmark] = [],
        history: [BrowserHistoryEntry] = [],
        adBlockEnabled: Bool = true,
        adBlockDisabledHosts: [String] = [],
        openExternalLinksInBrowser: Bool = true,
        searchEngine: BrowserSearchEngine = .duckDuckGo,
        siteZooms: [String: Double] = [:],
        profiles: [BrowserProfile] = [],
        activeProfileId: UUID? = nil,
        autofillEnabled: Bool = true,
        adBlockConfig: BrowserAdBlockConfig = .default,
        securityConfig: BrowserSecurityConfig = .default,
        layoutConfig: BrowserLayoutConfig = .default,
        darkModeConfig: BrowserDarkModeConfig = .default
    ) {
        self.tabs = tabs
        self.activeTabId = activeTabId
        self.bookmarks = bookmarks
        self.history = history
        self.adBlockEnabled = adBlockEnabled
        self.adBlockDisabledHosts = adBlockDisabledHosts
        self.openExternalLinksInBrowser = openExternalLinksInBrowser
        self.searchEngine = searchEngine
        self.siteZooms = siteZooms
        if profiles.isEmpty {
            let personal = BrowserProfile.defaultPersonal(
                tabs: tabs,
                activeTabId: activeTabId,
                bookmarks: bookmarks,
                history: history,
                adBlockDisabledHosts: adBlockDisabledHosts,
                siteZooms: siteZooms
            )
            self.profiles = [personal]
            self.activeProfileId = personal.id
        } else {
            self.profiles = profiles
            self.activeProfileId = activeProfileId ?? profiles.first?.id
        }
        self.autofillEnabled = autofillEnabled
        self.adBlockConfig = adBlockConfig
        self.securityConfig = securityConfig
        self.layoutConfig = layoutConfig
        self.darkModeConfig = darkModeConfig
    }

    public static let empty = BrowserPersistedState()

    enum CodingKeys: String, CodingKey {
        case tabs
        case activeTabId = "active_tab_id"
        case bookmarks
        case history
        case adBlockEnabled = "ad_block_enabled"
        case adBlockDisabledHosts = "ad_block_disabled_hosts"
        case openExternalLinksInBrowser = "open_external_links_in_browser"
        case searchEngine = "search_engine"
        case siteZooms = "site_zooms"
        case profiles
        case activeProfileId = "active_profile_id"
        case autofillEnabled = "autofill_enabled"
        case adBlockConfig = "ad_block_config"
        case securityConfig = "security_config"
        case layoutConfig = "layout_config"
        case darkModeConfig = "dark_mode_config"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tabs = try c.decodeIfPresent([BrowserTabRecord].self, forKey: .tabs) ?? []
        activeTabId = try c.decodeIfPresent(UUID.self, forKey: .activeTabId)
        bookmarks = try c.decodeIfPresent([BrowserBookmark].self, forKey: .bookmarks) ?? []
        history = try c.decodeIfPresent([BrowserHistoryEntry].self, forKey: .history) ?? []
        adBlockEnabled = try c.decodeIfPresent(Bool.self, forKey: .adBlockEnabled) ?? true
        adBlockDisabledHosts = try c.decodeIfPresent([String].self, forKey: .adBlockDisabledHosts) ?? []
        openExternalLinksInBrowser = try c.decodeIfPresent(Bool.self, forKey: .openExternalLinksInBrowser) ?? true
        searchEngine = try c.decodeIfPresent(BrowserSearchEngine.self, forKey: .searchEngine) ?? .duckDuckGo
        siteZooms = try c.decodeIfPresent([String: Double].self, forKey: .siteZooms) ?? [:]
        autofillEnabled = try c.decodeIfPresent(Bool.self, forKey: .autofillEnabled) ?? true
        adBlockConfig = try c.decodeIfPresent(BrowserAdBlockConfig.self, forKey: .adBlockConfig) ?? .default
        securityConfig = try c.decodeIfPresent(BrowserSecurityConfig.self, forKey: .securityConfig) ?? .default
        layoutConfig = try c.decodeIfPresent(BrowserLayoutConfig.self, forKey: .layoutConfig) ?? .default
        darkModeConfig = try c.decodeIfPresent(BrowserDarkModeConfig.self, forKey: .darkModeConfig) ?? .default

        let decodedProfiles = try c.decodeIfPresent([BrowserProfile].self, forKey: .profiles) ?? []
        if decodedProfiles.isEmpty {
            let personal = BrowserProfile.defaultPersonal(
                tabs: tabs,
                activeTabId: activeTabId,
                bookmarks: bookmarks,
                history: history,
                adBlockDisabledHosts: adBlockDisabledHosts,
                siteZooms: siteZooms
            )
            profiles = [personal]
            activeProfileId = personal.id
        } else {
            profiles = decodedProfiles
            let decodedActive = try c.decodeIfPresent(UUID.self, forKey: .activeProfileId)
            activeProfileId = decodedProfiles.contains(where: { $0.id == decodedActive }) ? decodedActive : decodedProfiles.first?.id
        }
    }
}

// MARK: - Persistence (browser.json)

public enum BrowserStorage {
    public static let maxHistoryEntries = 500

    public static func fileURL(dataDirectory: URL) -> URL {
        dataDirectory.appendingPathComponent("browser.json")
    }

    public static func extensionsDirectory(dataDirectory: URL) -> URL {
        dataDirectory.appendingPathComponent("browser-extensions", isDirectory: true)
    }

    public static func adBlockDirectory(dataDirectory: URL) -> URL {
        dataDirectory.appendingPathComponent("browser-adblock", isDirectory: true)
    }

    /// Loads persisted browser state; unreadable or malformed files fall back cleanly to `.empty`.
    /// Private tabs are always filtered out on load as defense-in-depth across all profiles.
    public static func load(from url: URL) -> BrowserPersistedState {
        guard let data = try? Data(contentsOf: url) else { return .empty }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let decoded = try? decoder.decode(BrowserPersistedState.self, from: data) else {
            return .empty
        }
        return sanitize(decoded)
    }

    /// Atomically persists browser state, stripping private tabs across all profiles before writing.
    public static func save(_ state: BrowserPersistedState, to url: URL) throws {
        let sanitized = sanitize(state)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(sanitized)
        data.append(0x0a)
        try data.write(to: url, options: .atomic)
    }

    private static func sanitize(_ state: BrowserPersistedState) -> BrowserPersistedState {
        var out = state
        out.tabs = sanitizeTabs(state.tabs)
        if let active = out.activeTabId, !out.tabs.contains(where: { $0.id == active }) {
            out.activeTabId = out.tabs.first?.id
        }
        if out.history.count > maxHistoryEntries {
            out.history = Array(out.history.prefix(maxHistoryEntries))
        }

        if out.profiles.isEmpty {
            let personal = BrowserProfile.defaultPersonal(
                tabs: out.tabs,
                activeTabId: out.activeTabId,
                bookmarks: out.bookmarks,
                history: out.history,
                adBlockDisabledHosts: out.adBlockDisabledHosts,
                siteZooms: out.siteZooms
            )
            out.profiles = [personal]
            out.activeProfileId = personal.id
        } else {
            out.profiles = out.profiles.map { profile in
                var p = profile
                let groupIDs = Set(p.tabGroups.map(\.id))
                p.tabs = sanitizeTabs(p.tabs).map { tab in
                    var t = tab
                    if let gid = t.groupId, !groupIDs.contains(gid) { t.groupId = nil }
                    return t
                }
                if let active = p.activeTabId, !p.tabs.contains(where: { $0.id == active }) {
                    p.activeTabId = p.tabs.first?.id
                }
                if let split = p.splitTabId,
                   split == p.activeTabId || !p.tabs.contains(where: { $0.id == split })
                {
                    p.splitTabId = nil
                }
                p.splitRatio = min(0.8, max(0.2, p.splitRatio))
                if p.history.count > maxHistoryEntries {
                    p.history = Array(p.history.prefix(maxHistoryEntries))
                }
                return p
            }
            if let active = out.activeProfileId, !out.profiles.contains(where: { $0.id == active }) {
                out.activeProfileId = out.profiles.first?.id
            }
        }
        // Mirror active profile fields into legacy top-level properties for older readers/tests.
        if let activeProfile = out.profiles.first(where: { $0.id == out.activeProfileId }) ?? out.profiles.first {
            out.tabs = activeProfile.tabs
            out.activeTabId = activeProfile.activeTabId
            out.bookmarks = activeProfile.bookmarks
            out.history = activeProfile.history
            out.adBlockDisabledHosts = activeProfile.adBlockDisabledHosts
            out.siteZooms = activeProfile.siteZooms
        }
        return out
    }

    private static func sanitizeTabs(_ tabs: [BrowserTabRecord]) -> [BrowserTabRecord] {
        tabs.filter { !$0.isPrivate }
    }
}
