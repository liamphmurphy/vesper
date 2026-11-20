import Foundation

/// A JSON value for the request bodies the policy builders produce (desktop `ApiRequest.body`).
public enum APIValue: Sendable, Equatable, Codable {
    case string(String)
    case int(Int)
    case bool(Bool)
    case array([APIValue])
    case object([String: APIValue])
    case null

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Int.self) { self = .int(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([APIValue].self) { self = .array(v) }
        else { self = .object(try c.decode([String: APIValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .int(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
}

extension APIValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByBooleanLiteral,
    ExpressibleByDictionaryLiteral, ExpressibleByArrayLiteral
{
    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int) { self = .int(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(dictionaryLiteral elements: (String, APIValue)...) { self = .object(Dictionary(uniqueKeysWithValues: elements)) }
    public init(arrayLiteral elements: APIValue...) { self = .array(elements) }
}

public typealias APIBody = [String: APIValue]

/// An API call a policy builder produced (notification actions, capture, sent files).
public struct APICall: Sendable, Equatable {
    public var method: String
    public var path: String
    public var body: APIBody
    public init(method: String = "POST", path: String, body: APIBody) {
        self.method = method
        self.path = path
        self.body = body
    }
}

public struct AgentRef: Sendable, Codable, Equatable {
    public var name: String?
    public var handle: String?
    public init(name: String? = nil, handle: String? = nil) {
        self.name = name
        self.handle = handle
    }
}

/// The fields of GET /api/v1/inbox items the app uses.
public struct InboxItem: Sendable, Codable, Equatable {
    public var id: String
    public var kind: String
    public var title: String
    public var summary: String?
    public var href: String
    public var ticketKey: String?
    public var createdAt: String
    public var resolved: Bool
    public var read: Bool
    public var needsYou: Bool
    public var agent: AgentRef?
    public var runId: String?

    enum CodingKeys: String, CodingKey {
        case id, kind, title, summary, href, resolved, read, agent
        case ticketKey = "ticket_key"
        case createdAt = "created_at"
        case needsYou = "needs_you"
        case runId = "run_id"
    }

    public init(
        id: String, kind: String, title: String, summary: String? = nil, href: String = "", ticketKey: String? = nil,
        createdAt: String = "", resolved: Bool = false, read: Bool = false, needsYou: Bool = false,
        agent: AgentRef? = nil, runId: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.summary = summary
        self.href = href
        self.ticketKey = ticketKey
        self.createdAt = createdAt
        self.resolved = resolved
        self.read = read
        self.needsYou = needsYou
        self.agent = agent
        self.runId = runId
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? ""
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        summary = try c.decodeIfPresent(String.self, forKey: .summary)
        href = try c.decodeIfPresent(String.self, forKey: .href) ?? ""
        ticketKey = try c.decodeIfPresent(String.self, forKey: .ticketKey)
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt) ?? ""
        resolved = try c.decodeIfPresent(Bool.self, forKey: .resolved) ?? false
        read = try c.decodeIfPresent(Bool.self, forKey: .read) ?? false
        needsYou = try c.decodeIfPresent(Bool.self, forKey: .needsYou) ?? false
        agent = try c.decodeIfPresent(AgentRef.self, forKey: .agent)
        runId = try c.decodeIfPresent(String.self, forKey: .runId)
    }
}

/// The fields of an API Run the app uses.
public struct RunSummary: Sendable, Codable, Equatable {
    public var id: String
    public var state: String
    public var purpose: String
    public var ticketKey: String?
    public var workTitle: String?
    public var waitReason: String?
    public var outcome: String?
    public var agent: AgentRef?

    enum CodingKeys: String, CodingKey {
        case id, state, purpose, outcome, agent
        case ticketKey = "ticket_key"
        case workTitle = "work_title"
        case waitReason = "wait_reason"
    }

    public init(
        id: String, state: String = "running", purpose: String = "ticket", ticketKey: String? = nil,
        workTitle: String? = nil, waitReason: String? = nil, outcome: String? = nil, agent: AgentRef? = nil
    ) {
        self.id = id
        self.state = state
        self.purpose = purpose
        self.ticketKey = ticketKey
        self.workTitle = workTitle
        self.waitReason = waitReason
        self.outcome = outcome
        self.agent = agent
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        state = try c.decodeIfPresent(String.self, forKey: .state) ?? ""
        purpose = try c.decodeIfPresent(String.self, forKey: .purpose) ?? ""
        ticketKey = try c.decodeIfPresent(String.self, forKey: .ticketKey)
        workTitle = try c.decodeIfPresent(String.self, forKey: .workTitle)
        waitReason = try c.decodeIfPresent(String.self, forKey: .waitReason)
        outcome = try c.decodeIfPresent(String.self, forKey: .outcome)
        agent = try c.decodeIfPresent(AgentRef.self, forKey: .agent)
    }
}

/// An alert the shell may show as a notification.
public struct DesktopAlert: Sendable, Equatable {
    public var title: String
    public var body: String
    public var href: String
    public var signature: String
    /// Inbox kind, or "run_finished" for run-finished alerts.
    public var kind: String
    /// Inbox item id (e.g. "approval:<uuid>"); empty for run-finished alerts.
    public var itemId: String
    public var runId: String?
    public var ticketKey: String?
    public var agentHandle: String?

    public init(
        title: String, body: String, href: String, signature: String, kind: String, itemId: String,
        runId: String? = nil, ticketKey: String? = nil, agentHandle: String? = nil
    ) {
        self.title = title
        self.body = body
        self.href = href
        self.signature = signature
        self.kind = kind
        self.itemId = itemId
        self.runId = runId
        self.ticketKey = ticketKey
        self.agentHandle = agentHandle
    }
}

/// The run image's state, GET /api/v1/system/vm-image.
public struct RootfsStatus: Sendable, Codable, Equatable {
    public enum State: String, Sendable, Codable { case checking, downloading, ready, error }
    public var state: State
    public var downloadedBytes: Int64?
    public var totalBytes: Int64?
    public var error: String?
    public init(state: State, downloadedBytes: Int64? = nil, totalBytes: Int64? = nil, error: String? = nil) {
        self.state = state
        self.downloadedBytes = downloadedBytes
        self.totalBytes = totalBytes
        self.error = error
    }
}

/// GET /api/v1/runner: whether a runner is connected, and each runner's capacity.
public struct RunnerStatus: Sendable, Codable, Equatable {
    public struct Runner: Sendable, Codable, Equatable {
        public var maxConcurrent: Int?
        public var slotLimit: Int?
        public var hostWorkspacesDir: String?
        enum CodingKeys: String, CodingKey {
            case maxConcurrent = "max_concurrent"
            case slotLimit = "slot_limit"
            case hostWorkspacesDir = "host_workspaces_dir"
        }
        public init(maxConcurrent: Int? = nil, slotLimit: Int? = nil, hostWorkspacesDir: String? = nil) {
            self.maxConcurrent = maxConcurrent
            self.slotLimit = slotLimit
            self.hostWorkspacesDir = hostWorkspacesDir
        }
    }
    public var online: Bool?
    public var runners: [Runner]?
    public var starting: Bool?
    public init(online: Bool? = nil, runners: [Runner]? = nil, starting: Bool? = nil) {
        self.online = online
        self.runners = runners
        self.starting = starting
    }
}

/// GET /api/v1/instance/backup-encryption.
public struct BackupEncryptionStatus: Sendable, Codable, Equatable {
    public var enabled: Bool
    public var keyConfigured: Bool
    public var updatedAt: String?

    enum CodingKeys: String, CodingKey {
        case enabled
        case keyConfigured = "key_configured"
        case updatedAt = "updated_at"
    }

    public init(enabled: Bool, keyConfigured: Bool, updatedAt: String? = nil) {
        self.enabled = enabled
        self.keyConfigured = keyConfigured
        self.updatedAt = updatedAt
    }
}

extension APIClient {
    /// The roots workspace folders may be opened in: each runner's `host_workspaces_dir`.
    public func workspaceRoots() async -> [String] {
        guard let status: RunnerStatus = try? await get("/api/v1/runner", timeout: 4) else { return [] }
        return (status.runners ?? []).compactMap(\.hostWorkspacesDir).filter { $0.hasPrefix("/") }
    }

    /// PUT /api/v1/runner/slot-limit (thermal easing). nil lifts the cap.
    public func setSlotLimit(_ limit: Int?) async throws {
        let body: APIBody = ["limit": limit.map { .int($0) } ?? .null]
        try await send(APICall(method: "PUT", path: "/api/v1/runner/slot-limit", body: body))
    }
}
