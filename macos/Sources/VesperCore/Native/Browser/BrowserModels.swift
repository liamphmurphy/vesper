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

    public init(
        id: UUID = UUID(),
        name: String,
        color: BrowserProfileColor = .blue,
        isCollapsed: Bool = false
    ) {
        self.id = id
        self.name = name
        self.color = color
        self.isCollapsed = isCollapsed
    }

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case color
        case isCollapsed = "is_collapsed"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Group"
        color = try c.decodeIfPresent(BrowserProfileColor.self, forKey: .color) ?? .blue
        isCollapsed = try c.decodeIfPresent(Bool.self, forKey: .isCollapsed) ?? false
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
        autofillNeverSaveHosts: [String] = []
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
        adBlockConfig: BrowserAdBlockConfig = .default
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
