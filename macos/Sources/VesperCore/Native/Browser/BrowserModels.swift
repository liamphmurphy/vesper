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

// MARK: - Persisted Browser Records

public struct BrowserTabRecord: Codable, Sendable, Equatable, Hashable, Identifiable {
    public var id: UUID
    public var url: String
    public var title: String
    public var isPinned: Bool
    public var isPrivate: Bool
    public var zoom: Double

    public init(
        id: UUID = UUID(),
        url: String = "",
        title: String = "New Tab",
        isPinned: Bool = false,
        isPrivate: Bool = false,
        zoom: Double = 1.0
    ) {
        self.id = id
        self.url = url
        self.title = title
        self.isPinned = isPinned
        self.isPrivate = isPrivate
        self.zoom = zoom
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

    public init(
        tabs: [BrowserTabRecord] = [],
        activeTabId: UUID? = nil,
        bookmarks: [BrowserBookmark] = [],
        history: [BrowserHistoryEntry] = [],
        adBlockEnabled: Bool = true,
        adBlockDisabledHosts: [String] = [],
        openExternalLinksInBrowser: Bool = true,
        searchEngine: BrowserSearchEngine = .duckDuckGo,
        siteZooms: [String: Double] = [:]
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
    }
}

// MARK: - Persistence (browser.json)

public enum BrowserStorage {
    public static let maxHistoryEntries = 500

    public static func fileURL(dataDirectory: URL) -> URL {
        dataDirectory.appendingPathComponent("browser.json")
    }

    /// Loads persisted browser state; unreadable or malformed files fall back cleanly to `.empty`.
    /// Private tabs are always filtered out on load as defense-in-depth.
    public static func load(from url: URL) -> BrowserPersistedState {
        guard let data = try? Data(contentsOf: url) else { return .empty }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard var decoded = try? decoder.decode(BrowserPersistedState.self, from: data) else {
            return .empty
        }
        decoded.tabs = decoded.tabs.filter { !$0.isPrivate }
        if let active = decoded.activeTabId, !decoded.tabs.contains(where: { $0.id == active }) {
            decoded.activeTabId = decoded.tabs.first?.id
        }
        if decoded.history.count > maxHistoryEntries {
            decoded.history = Array(decoded.history.prefix(maxHistoryEntries))
        }
        return decoded
    }

    /// Atomically persists browser state, stripping private tabs before writing to disk.
    public static func save(_ state: BrowserPersistedState, to url: URL) throws {
        var sanitized = state
        sanitized.tabs = state.tabs.filter { !$0.isPrivate }
        if let active = sanitized.activeTabId, !sanitized.tabs.contains(where: { $0.id == active }) {
            sanitized.activeTabId = sanitized.tabs.first?.id
        }
        if sanitized.history.count > maxHistoryEntries {
            sanitized.history = Array(sanitized.history.prefix(maxHistoryEntries))
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(sanitized)
        data.append(0x0a)
        try data.write(to: url, options: .atomic)
    }
}
