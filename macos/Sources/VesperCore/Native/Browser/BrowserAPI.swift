import Foundation

// MARK: - Browser Extension API Models (matches server/internal/httpapi/browser_extension.go)

public struct BrowserExtensionPersona: Codable, Sendable, Equatable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var isDefault: Bool

    enum CodingKeys: String, CodingKey {
        case id, name
        case isDefault = "is_default"
    }

    public init(id: String, name: String, isDefault: Bool = false) {
        self.id = id
        self.name = name
        self.isDefault = isDefault
    }
}

public struct BrowserExtensionChat: Codable, Sendable, Equatable, Hashable, Identifiable {
    public var id: String
    public var title: String
    public var personaId: String?

    enum CodingKeys: String, CodingKey {
        case id, title
        case personaId = "persona_id"
    }

    public init(id: String, title: String, personaId: String? = nil) {
        self.id = id
        self.title = title
        self.personaId = personaId
    }
}

public struct BrowserShareRead: Codable, Sendable, Equatable, Hashable {
    public var persona: String
    public var url: String
    public var readAt: String

    enum CodingKeys: String, CodingKey {
        case persona, url
        case readAt = "read_at"
    }

    public init(persona: String, url: String, readAt: String) {
        self.persona = persona
        self.url = url
        self.readAt = readAt
    }
}

public struct BrowserShare: Codable, Sendable, Equatable, Hashable, Identifiable {
    public var id: String
    public var chatId: String
    public var chatTitle: String
    public var tabId: String
    public var url: String
    public var title: String
    public var until: String
    public var includeScreenshot: Bool
    public var startedAt: String
    public var snapshotAt: String?
    public var stoppedAt: String?
    public var stopReason: String
    public var reads: [BrowserShareRead]

    enum CodingKeys: String, CodingKey {
        case id
        case chatId = "chat_id"
        case chatTitle = "chat_title"
        case tabId = "tab_id"
        case url, title, until
        case includeScreenshot = "include_screenshot"
        case startedAt = "started_at"
        case snapshotAt = "snapshot_at"
        case stoppedAt = "stopped_at"
        case stopReason = "stop_reason"
        case reads
    }

    public init(
        id: String,
        chatId: String,
        chatTitle: String = "",
        tabId: String,
        url: String,
        title: String,
        until: String,
        includeScreenshot: Bool,
        startedAt: String = "",
        snapshotAt: String? = nil,
        stoppedAt: String? = nil,
        stopReason: String = "",
        reads: [BrowserShareRead] = []
    ) {
        self.id = id
        self.chatId = chatId
        self.chatTitle = chatTitle
        self.tabId = tabId
        self.url = url
        self.title = title
        self.until = until
        self.includeScreenshot = includeScreenshot
        self.startedAt = startedAt
        self.snapshotAt = snapshotAt
        self.stoppedAt = stoppedAt
        self.stopReason = stopReason
        self.reads = reads
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        chatId = try c.decode(String.self, forKey: .chatId)
        chatTitle = try c.decodeIfPresent(String.self, forKey: .chatTitle) ?? ""
        tabId = try c.decodeIfPresent(String.self, forKey: .tabId) ?? ""
        url = try c.decodeIfPresent(String.self, forKey: .url) ?? ""
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        until = try c.decodeIfPresent(String.self, forKey: .until) ?? "page"
        includeScreenshot = try c.decodeIfPresent(Bool.self, forKey: .includeScreenshot) ?? false
        startedAt = try c.decodeIfPresent(String.self, forKey: .startedAt) ?? ""
        snapshotAt = try c.decodeIfPresent(String.self, forKey: .snapshotAt)
        stoppedAt = try c.decodeIfPresent(String.self, forKey: .stoppedAt)
        stopReason = try c.decodeIfPresent(String.self, forKey: .stopReason) ?? ""
        reads = try c.decodeIfPresent([BrowserShareRead].self, forKey: .reads) ?? []
    }
}

public struct BrowserExtensionConfig: Codable, Sendable, Equatable {
    public var personas: [BrowserExtensionPersona]
    public var chats: [BrowserExtensionChat]
    public var neverShare: BrowserNeverShareLists
    public var shares: [BrowserShare]

    enum CodingKeys: String, CodingKey {
        case personas, chats
        case neverShare = "never_share"
        case shares
    }

    public init(
        personas: [BrowserExtensionPersona] = [],
        chats: [BrowserExtensionChat] = [],
        neverShare: BrowserNeverShareLists = BrowserNeverShareLists(),
        shares: [BrowserShare] = []
    ) {
        self.personas = personas
        self.chats = chats
        self.neverShare = neverShare
        self.shares = shares
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        personas = try c.decodeIfPresent([BrowserExtensionPersona].self, forKey: .personas) ?? []
        chats = try c.decodeIfPresent([BrowserExtensionChat].self, forKey: .chats) ?? []
        neverShare = try c.decodeIfPresent(BrowserNeverShareLists.self, forKey: .neverShare) ?? BrowserNeverShareLists()
        shares = try c.decodeIfPresent([BrowserShare].self, forKey: .shares) ?? []
    }
}

public struct BrowserSnapshotPayload: Encodable, Sendable, Equatable {
    public var url: String
    public var title: String
    public var text: String
    public var screenshot: String?
    public var incognito: Bool

    public init(url: String, title: String, text: String, screenshot: String? = nil, incognito: Bool = false) {
        self.url = url
        self.title = title
        self.text = text
        self.screenshot = screenshot
        self.incognito = incognito
    }
}

public struct BrowserShareStartRequest: Encodable, Sendable, Equatable {
    public var url: String
    public var title: String
    public var text: String
    public var screenshot: String?
    public var incognito: Bool
    public var chatId: String?
    public var personaId: String?
    public var tabId: String
    public var until: String
    public var includeScreenshot: Bool

    enum CodingKeys: String, CodingKey {
        case url, title, text, screenshot, incognito
        case chatId = "chat_id"
        case personaId = "persona_id"
        case tabId = "tab_id"
        case until
        case includeScreenshot = "include_screenshot"
    }

    public init(
        snapshot: BrowserSnapshotPayload,
        chatId: String? = nil,
        personaId: String? = nil,
        tabId: String,
        until: String = "page",
        includeScreenshot: Bool = false
    ) {
        self.url = snapshot.url
        self.title = snapshot.title
        self.text = snapshot.text
        self.screenshot = snapshot.screenshot
        self.incognito = snapshot.incognito
        self.chatId = chatId
        self.personaId = personaId
        self.tabId = tabId
        self.until = until
        self.includeScreenshot = includeScreenshot
    }
}

public struct BrowserAskRequest: Encodable, Sendable, Equatable {
    public var personaId: String?
    public var prompt: String
    public var url: String
    public var title: String
    public var selection: String
    public var incognito: Bool

    enum CodingKeys: String, CodingKey {
        case personaId = "persona_id"
        case prompt, url, title, selection, incognito
    }

    public init(
        personaId: String? = nil,
        prompt: String,
        url: String,
        title: String,
        selection: String = "",
        incognito: Bool = false
    ) {
        self.personaId = personaId
        self.prompt = prompt
        self.url = url
        self.title = title
        self.selection = selection
        self.incognito = incognito
    }
}

public struct BrowserAskResponse: Codable, Sendable, Equatable {
    public var chatId: String
    public var href: String

    enum CodingKeys: String, CodingKey {
        case chatId = "chat_id"
        case href
    }

    public init(chatId: String, href: String) {
        self.chatId = chatId
        self.href = href
    }
}

public enum BrowserClipKind: String, Encodable, Sendable {
    case note
    case link
}

public struct BrowserClipRequest: Encodable, Sendable, Equatable {
    public var `as`: BrowserClipKind
    public var url: String
    public var title: String
    public var selection: String
    public var incognito: Bool

    public init(as kind: BrowserClipKind, url: String, title: String, selection: String = "", incognito: Bool = false) {
        self.as = kind
        self.url = url
        self.title = title
        self.selection = selection
        self.incognito = incognito
    }
}

public struct BrowserClipResponse: Codable, Sendable, Equatable {
    public var kind: String
    public var id: String
    public var href: String
    public var state: String

    public init(kind: String, id: String, href: String, state: String) {
        self.kind = kind
        self.id = id
        self.href = href
        self.state = state
    }
}

// MARK: - Browser Extension API Client

/// Calls `/api/v1/browser-extension/*` using a bearer token supplied by `tokenProvider`.
/// Because `APIClient` sends the session cookie, we create a bearer-scoped `APIClient` for
/// extension routes (which specifically authenticate via the extension bearer token).
public struct BrowserExtensionClient: Sendable {
    public typealias TokenProvider = @Sendable (_ forceRefresh: Bool) async throws -> String

    private let baseURL: URL
    private let transport: HTTPTransport?
    private let tokenProvider: TokenProvider

    public init(baseURL: URL, transport: HTTPTransport? = nil, tokenProvider: @escaping TokenProvider) {
        self.baseURL = baseURL
        self.transport = transport
        self.tokenProvider = tokenProvider
    }

    private func perform<T: Decodable>(
        _ method: String,
        _ subpath: String,
        body: Data? = nil,
        timeout: TimeInterval = 20
    ) async throws -> T {
        let data = try await performRaw(method, subpath, body: body, timeout: timeout)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw APIError.decoding("\(error)")
        }
    }

    private func performRaw(
        _ method: String,
        _ subpath: String,
        body: Data? = nil,
        timeout: TimeInterval = 20
    ) async throws -> Data {
        let path = "/api/v1/browser-extension/" + subpath
        let token = try await tokenProvider(false)
        do {
            let client = APIClient(baseURL: baseURL, auth: .bearer(token), transport: transport)
            return try await client.request(method, path, body: body, timeout: timeout)
        } catch APIError.unauthorized {
            // Token may have been rotated; mint once and retry.
            let fresh = try await tokenProvider(true)
            let client = APIClient(baseURL: baseURL, auth: .bearer(fresh), transport: transport)
            return try await client.request(method, path, body: body, timeout: timeout)
        }
    }

    public func fetchConfig() async throws -> BrowserExtensionConfig {
        try await perform("GET", "config")
    }

    public func startShare(_ req: BrowserShareStartRequest) async throws -> BrowserShare {
        let data = try JSONEncoder().encode(req)
        return try await perform("POST", "shares", body: data, timeout: 30)
    }

    public func getShare(id: String) async throws -> BrowserShare {
        try await perform("GET", "shares/\(APIPath.escape(id))")
    }

    public func sendSnapshot(shareId: String, snapshot: BrowserSnapshotPayload) async throws -> BrowserShare {
        let data = try JSONEncoder().encode(snapshot)
        return try await perform("POST", "shares/\(APIPath.escape(shareId))/snapshot", body: data, timeout: 30)
    }

    public func stopShare(shareId: String, reason: String = "person") async throws -> BrowserShare {
        let data = try JSONEncoder().encode(["reason": reason])
        return try await perform("POST", "shares/\(APIPath.escape(shareId))/stop", body: data)
    }

    public func ask(_ req: BrowserAskRequest) async throws -> BrowserAskResponse {
        let data = try JSONEncoder().encode(req)
        return try await perform("POST", "ask", body: data, timeout: 30)
    }

    public func clip(_ req: BrowserClipRequest) async throws -> BrowserClipResponse {
        let data = try JSONEncoder().encode(req)
        return try await perform("POST", "clip", body: data, timeout: 30)
    }

    public func addNeverShare(host: String) async throws -> BrowserExtensionConfig {
        let data = try JSONEncoder().encode(["host": host])
        return try await perform("POST", "never-share", body: data)
    }

    public func removeNeverShare(host: String) async throws -> BrowserExtensionConfig {
        try await perform("DELETE", "never-share/\(APIPath.escape(host))")
    }
}
