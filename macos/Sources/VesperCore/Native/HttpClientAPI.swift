import Foundation

// MARK: - Enums

public enum HttpAuthType: String, Codable, Sendable, CaseIterable, Hashable, Identifiable {
    case inherit
    case none
    case bearer
    case basic
    case apikey
    case oauth2

    public var id: String { rawValue }

    public init(from decoder: any Decoder) throws {
        let raw = (try? decoder.singleValueContainer().decode(String.self))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        self = HttpAuthType(rawValue: raw) ?? .none
    }
}

public enum HttpAPIKeyPlacement: String, Codable, Sendable, CaseIterable, Hashable, Identifiable {
    case header
    case query

    public var id: String { rawValue }

    public init(from decoder: any Decoder) throws {
        let raw = (try? decoder.singleValueContainer().decode(String.self))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        self = HttpAPIKeyPlacement(rawValue: raw) ?? .header
    }
}

public enum HttpBodyMode: String, Codable, Sendable, CaseIterable, Hashable, Identifiable {
    case none
    case json
    case raw
    case formUrlencoded = "form_urlencoded"
    case multipart

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .none: "None"
        case .json: "JSON"
        case .raw: "Raw text"
        case .formUrlencoded: "Form URL-encoded"
        case .multipart: "Multipart form"
        }
    }

    public init(from decoder: any Decoder) throws {
        let raw = (try? decoder.singleValueContainer().decode(String.self))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        self = HttpBodyMode(rawValue: raw) ?? .none
    }
}

public enum HttpEnvColor: String, Codable, Sendable, CaseIterable, Hashable, Identifiable {
    case green
    case amber
    case red
    case blue
    case purple
    case gray

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .green: "Green (nonprod/dev)"
        case .amber: "Amber (staging)"
        case .red: "Red (prod)"
        case .blue: "Blue"
        case .purple: "Purple"
        case .gray: "Gray"
        }
    }

    public init(from decoder: any Decoder) throws {
        let raw = (try? decoder.singleValueContainer().decode(String.self))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        self = HttpEnvColor(rawValue: raw) ?? .green
    }
}

public enum HttpImportFormat: String, Codable, Sendable, CaseIterable, Hashable, Identifiable {
    case bru
    case curl
    case openapi

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .bru: "Bruno (.bru / .zip)"
        case .curl: "cURL"
        case .openapi: "OpenAPI 3"
        }
    }
}

// MARK: - Core Value Types

public struct HttpKeyValue: Codable, Sendable, Equatable, Hashable {
    public var key: String
    public var value: String
    public var enabled: Bool

    public init(key: String = "", value: String = "", enabled: Bool = true) {
        self.key = key
        self.value = value
        self.enabled = enabled
    }

    enum CodingKeys: String, CodingKey {
        case key, value, enabled
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.key = try c.decodeIfPresent(String.self, forKey: .key) ?? ""
        self.value = try c.decodeIfPresent(String.self, forKey: .value) ?? ""
        self.enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    }
}

public struct HttpEnvVar: Codable, Sendable, Equatable, Hashable {
    public var key: String
    public var value: String
    public var secretHandle: String
    public var enabled: Bool

    public init(key: String = "", value: String = "", secretHandle: String = "", enabled: Bool = true) {
        self.key = key
        self.value = value
        self.secretHandle = secretHandle
        self.enabled = enabled
    }

    enum CodingKeys: String, CodingKey {
        case key, value
        case secretHandle = "secret_handle"
        case enabled
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.key = try c.decodeIfPresent(String.self, forKey: .key) ?? ""
        self.value = try c.decodeIfPresent(String.self, forKey: .value) ?? ""
        self.secretHandle = try c.decodeIfPresent(String.self, forKey: .secretHandle) ?? ""
        self.enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(key, forKey: .key)
        try c.encode(value, forKey: .value)
        if !secretHandle.isEmpty {
            try c.encode(secretHandle, forKey: .secretHandle)
        }
        try c.encode(enabled, forKey: .enabled)
    }
}

public struct HttpOAuth2Config: Codable, Sendable, Equatable, Hashable {
    public var grantType: String
    public var tokenUrl: String
    public var clientId: String
    public var clientSecret: String
    public var scope: String
    public var audience: String

    public init(
        grantType: String = "client_credentials",
        tokenUrl: String = "",
        clientId: String = "",
        clientSecret: String = "",
        scope: String = "",
        audience: String = ""
    ) {
        self.grantType = grantType.isEmpty ? "client_credentials" : grantType
        self.tokenUrl = tokenUrl
        self.clientId = clientId
        self.clientSecret = clientSecret
        self.scope = scope
        self.audience = audience
    }

    enum CodingKeys: String, CodingKey {
        case grantType = "grant_type"
        case tokenUrl = "token_url"
        case clientId = "client_id"
        case clientSecret = "client_secret"
        case scope, audience
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let gt = try c.decodeIfPresent(String.self, forKey: .grantType) ?? ""
        self.grantType = gt.isEmpty ? "client_credentials" : gt
        self.tokenUrl = try c.decodeIfPresent(String.self, forKey: .tokenUrl) ?? ""
        self.clientId = try c.decodeIfPresent(String.self, forKey: .clientId) ?? ""
        self.clientSecret = try c.decodeIfPresent(String.self, forKey: .clientSecret) ?? ""
        self.scope = try c.decodeIfPresent(String.self, forKey: .scope) ?? ""
        self.audience = try c.decodeIfPresent(String.self, forKey: .audience) ?? ""
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(grantType.isEmpty ? "client_credentials" : grantType, forKey: .grantType)
        if !tokenUrl.isEmpty { try c.encode(tokenUrl, forKey: .tokenUrl) }
        if !clientId.isEmpty { try c.encode(clientId, forKey: .clientId) }
        if !clientSecret.isEmpty { try c.encode(clientSecret, forKey: .clientSecret) }
        if !scope.isEmpty { try c.encode(scope, forKey: .scope) }
        if !audience.isEmpty { try c.encode(audience, forKey: .audience) }
    }
}

public struct HttpAuthConfig: Codable, Sendable, Equatable, Hashable {
    public var type: HttpAuthType
    public var token: String?
    public var username: String?
    public var password: String?
    public var apiKeyName: String?
    public var apiKeyValue: String?
    public var apiKeyIn: HttpAPIKeyPlacement?
    public var oauth2: HttpOAuth2Config?

    public static let none = HttpAuthConfig(type: .none)
    public static let inherit = HttpAuthConfig(type: .inherit)

    public init(
        type: HttpAuthType = .none,
        token: String? = nil,
        username: String? = nil,
        password: String? = nil,
        apiKeyName: String? = nil,
        apiKeyValue: String? = nil,
        apiKeyIn: HttpAPIKeyPlacement? = nil,
        oauth2: HttpOAuth2Config? = nil
    ) {
        self.type = type
        self.token = token
        self.username = username
        self.password = password
        self.apiKeyName = apiKeyName
        self.apiKeyValue = apiKeyValue
        self.apiKeyIn = apiKeyIn
        self.oauth2 = oauth2
    }

    enum CodingKeys: String, CodingKey {
        case type, token, username, password
        case apiKeyName = "api_key_name"
        case apiKeyValue = "api_key_value"
        case apiKeyIn = "api_key_in"
        case oauth2
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.type = try c.decodeIfPresent(HttpAuthType.self, forKey: .type) ?? .none
        self.token = try c.decodeIfPresent(String.self, forKey: .token)
        self.username = try c.decodeIfPresent(String.self, forKey: .username)
        self.password = try c.decodeIfPresent(String.self, forKey: .password)
        self.apiKeyName = try c.decodeIfPresent(String.self, forKey: .apiKeyName)
        self.apiKeyValue = try c.decodeIfPresent(String.self, forKey: .apiKeyValue)
        if let rawIn = try c.decodeIfPresent(String.self, forKey: .apiKeyIn)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(), !rawIn.isEmpty
        {
            self.apiKeyIn = HttpAPIKeyPlacement(rawValue: rawIn) ?? .header
        } else {
            self.apiKeyIn = nil
        }
        self.oauth2 = try c.decodeIfPresent(HttpOAuth2Config.self, forKey: .oauth2)
    }
}

// MARK: - Domain Entities

public struct HttpWorkspace: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var description: String
    public var activeEnvironmentId: String?
    public var defaultAuth: HttpAuthConfig
    public var defaultHeaders: [HttpKeyValue]
    public var defaultVars: [HttpEnvVar]
    public var createdAt: String
    public var updatedAt: String

    public init(
        id: String,
        name: String,
        description: String = "",
        activeEnvironmentId: String? = nil,
        defaultAuth: HttpAuthConfig = .none,
        defaultHeaders: [HttpKeyValue] = [],
        defaultVars: [HttpEnvVar] = [],
        createdAt: String = "",
        updatedAt: String = ""
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.activeEnvironmentId = activeEnvironmentId
        self.defaultAuth = defaultAuth
        self.defaultHeaders = defaultHeaders
        self.defaultVars = defaultVars
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey {
        case id, name, description
        case activeEnvironmentId = "active_environment_id"
        case defaultAuth = "default_auth"
        case defaultHeaders = "default_headers"
        case defaultVars = "default_vars"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.name = try c.decode(String.self, forKey: .name)
        self.description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
        self.activeEnvironmentId = try c.decodeIfPresent(String.self, forKey: .activeEnvironmentId)
        self.defaultAuth = try c.decodeIfPresent(HttpAuthConfig.self, forKey: .defaultAuth) ?? .none
        self.defaultHeaders = try c.decodeIfPresent([HttpKeyValue].self, forKey: .defaultHeaders) ?? []
        self.defaultVars = try c.decodeIfPresent([HttpEnvVar].self, forKey: .defaultVars) ?? []
        self.createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt) ?? ""
        self.updatedAt = try c.decodeIfPresent(String.self, forKey: .updatedAt) ?? ""
    }
}

public struct HttpEnvironment: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var httpWorkspaceId: String
    public var name: String
    public var color: HttpEnvColor
    public var variables: [HttpEnvVar]
    public var sortOrder: Int
    public var createdAt: String
    public var updatedAt: String

    public init(
        id: String,
        httpWorkspaceId: String,
        name: String,
        color: HttpEnvColor = .green,
        variables: [HttpEnvVar] = [],
        sortOrder: Int = 0,
        createdAt: String = "",
        updatedAt: String = ""
    ) {
        self.id = id
        self.httpWorkspaceId = httpWorkspaceId
        self.name = name
        self.color = color
        self.variables = variables
        self.sortOrder = sortOrder
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey {
        case id
        case httpWorkspaceId = "http_workspace_id"
        case name, color, variables
        case sortOrder = "sort_order"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.httpWorkspaceId = try c.decode(String.self, forKey: .httpWorkspaceId)
        self.name = try c.decode(String.self, forKey: .name)
        self.color = try c.decodeIfPresent(HttpEnvColor.self, forKey: .color) ?? .green
        self.variables = try c.decodeIfPresent([HttpEnvVar].self, forKey: .variables) ?? []
        self.sortOrder = try c.decodeIfPresent(Int.self, forKey: .sortOrder) ?? 0
        self.createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt) ?? ""
        self.updatedAt = try c.decodeIfPresent(String.self, forKey: .updatedAt) ?? ""
    }
}

public struct HttpFolder: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var httpWorkspaceId: String
    public var parentFolderId: String?
    public var name: String
    public var defaultAuth: HttpAuthConfig
    public var defaultHeaders: [HttpKeyValue]
    public var sortOrder: Int
    public var createdAt: String
    public var updatedAt: String

    public init(
        id: String,
        httpWorkspaceId: String,
        parentFolderId: String? = nil,
        name: String,
        defaultAuth: HttpAuthConfig = .inherit,
        defaultHeaders: [HttpKeyValue] = [],
        sortOrder: Int = 0,
        createdAt: String = "",
        updatedAt: String = ""
    ) {
        self.id = id
        self.httpWorkspaceId = httpWorkspaceId
        self.parentFolderId = parentFolderId
        self.name = name
        self.defaultAuth = defaultAuth
        self.defaultHeaders = defaultHeaders
        self.sortOrder = sortOrder
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey {
        case id
        case httpWorkspaceId = "http_workspace_id"
        case parentFolderId = "parent_folder_id"
        case name
        case defaultAuth = "default_auth"
        case defaultHeaders = "default_headers"
        case sortOrder = "sort_order"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.httpWorkspaceId = try c.decode(String.self, forKey: .httpWorkspaceId)
        self.parentFolderId = try c.decodeIfPresent(String.self, forKey: .parentFolderId)
        self.name = try c.decode(String.self, forKey: .name)
        self.defaultAuth = try c.decodeIfPresent(HttpAuthConfig.self, forKey: .defaultAuth) ?? .inherit
        self.defaultHeaders = try c.decodeIfPresent([HttpKeyValue].self, forKey: .defaultHeaders) ?? []
        self.sortOrder = try c.decodeIfPresent(Int.self, forKey: .sortOrder) ?? 0
        self.createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt) ?? ""
        self.updatedAt = try c.decodeIfPresent(String.self, forKey: .updatedAt) ?? ""
    }
}

public struct HttpRequest: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var httpWorkspaceId: String
    public var folderId: String?
    public var name: String
    public var method: String
    public var url: String
    public var params: [HttpKeyValue]
    public var headers: [HttpKeyValue]
    public var auth: HttpAuthConfig
    public var bodyMode: HttpBodyMode
    public var body: String
    public var bodyForm: [HttpKeyValue]
    public var timeoutMs: Int
    public var followRedirects: Bool
    public var sortOrder: Int
    public var createdAt: String
    public var updatedAt: String

    public init(
        id: String,
        httpWorkspaceId: String,
        folderId: String? = nil,
        name: String,
        method: String = "GET",
        url: String = "",
        params: [HttpKeyValue] = [],
        headers: [HttpKeyValue] = [],
        auth: HttpAuthConfig = .inherit,
        bodyMode: HttpBodyMode = .none,
        body: String = "",
        bodyForm: [HttpKeyValue] = [],
        timeoutMs: Int = 30000,
        followRedirects: Bool = true,
        sortOrder: Int = 0,
        createdAt: String = "",
        updatedAt: String = ""
    ) {
        self.id = id
        self.httpWorkspaceId = httpWorkspaceId
        self.folderId = folderId
        self.name = name
        self.method = method
        self.url = url
        self.params = params
        self.headers = headers
        self.auth = auth
        self.bodyMode = bodyMode
        self.body = body
        self.bodyForm = bodyForm
        self.timeoutMs = timeoutMs
        self.followRedirects = followRedirects
        self.sortOrder = sortOrder
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey {
        case id
        case httpWorkspaceId = "http_workspace_id"
        case folderId = "folder_id"
        case name, method, url, params, headers, auth
        case bodyMode = "body_mode"
        case body
        case bodyForm = "body_form"
        case timeoutMs = "timeout_ms"
        case followRedirects = "follow_redirects"
        case sortOrder = "sort_order"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.httpWorkspaceId = try c.decode(String.self, forKey: .httpWorkspaceId)
        self.folderId = try c.decodeIfPresent(String.self, forKey: .folderId)
        self.name = try c.decode(String.self, forKey: .name)
        self.method = try c.decodeIfPresent(String.self, forKey: .method) ?? "GET"
        self.url = try c.decodeIfPresent(String.self, forKey: .url) ?? ""
        self.params = try c.decodeIfPresent([HttpKeyValue].self, forKey: .params) ?? []
        self.headers = try c.decodeIfPresent([HttpKeyValue].self, forKey: .headers) ?? []
        self.auth = try c.decodeIfPresent(HttpAuthConfig.self, forKey: .auth) ?? .inherit
        self.bodyMode = try c.decodeIfPresent(HttpBodyMode.self, forKey: .bodyMode) ?? .none
        self.body = try c.decodeIfPresent(String.self, forKey: .body) ?? ""
        self.bodyForm = try c.decodeIfPresent([HttpKeyValue].self, forKey: .bodyForm) ?? []
        self.timeoutMs = try c.decodeIfPresent(Int.self, forKey: .timeoutMs) ?? 30000
        self.followRedirects = try c.decodeIfPresent(Bool.self, forKey: .followRedirects) ?? true
        self.sortOrder = try c.decodeIfPresent(Int.self, forKey: .sortOrder) ?? 0
        self.createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt) ?? ""
        self.updatedAt = try c.decodeIfPresent(String.self, forKey: .updatedAt) ?? ""
    }
}

public struct HttpExecution: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var httpWorkspaceId: String
    public var requestId: String?
    public var environmentId: String?
    public var environmentName: String
    public var method: String
    public var resolvedUrl: String
    public var requestHeaders: [String: String]
    public var requestBody: String
    public var statusCode: Int
    public var statusText: String
    public var durationMs: Int
    public var sizeBytes: Int
    public var responseHeaders: [String: [String]]
    public var responseBody: String
    public var responseTruncated: Bool
    public var error: String?
    public var createdAt: String

    public init(
        id: String,
        httpWorkspaceId: String,
        requestId: String? = nil,
        environmentId: String? = nil,
        environmentName: String = "",
        method: String = "GET",
        resolvedUrl: String = "",
        requestHeaders: [String: String] = [:],
        requestBody: String = "",
        statusCode: Int = 0,
        statusText: String = "",
        durationMs: Int = 0,
        sizeBytes: Int = 0,
        responseHeaders: [String: [String]] = [:],
        responseBody: String = "",
        responseTruncated: Bool = false,
        error: String? = nil,
        createdAt: String = ""
    ) {
        self.id = id
        self.httpWorkspaceId = httpWorkspaceId
        self.requestId = requestId
        self.environmentId = environmentId
        self.environmentName = environmentName
        self.method = method
        self.resolvedUrl = resolvedUrl
        self.requestHeaders = requestHeaders
        self.requestBody = requestBody
        self.statusCode = statusCode
        self.statusText = statusText
        self.durationMs = durationMs
        self.sizeBytes = sizeBytes
        self.responseHeaders = responseHeaders
        self.responseBody = responseBody
        self.responseTruncated = responseTruncated
        self.error = error.flatMap { $0.isEmpty ? nil : $0 }
        self.createdAt = createdAt
    }

    enum CodingKeys: String, CodingKey {
        case id
        case httpWorkspaceId = "http_workspace_id"
        case requestId = "request_id"
        case environmentId = "environment_id"
        case environmentName = "environment_name"
        case method
        case resolvedUrl = "resolved_url"
        case requestHeaders = "request_headers"
        case requestBody = "request_body"
        case statusCode = "status_code"
        case statusText = "status_text"
        case durationMs = "duration_ms"
        case sizeBytes = "size_bytes"
        case responseHeaders = "response_headers"
        case responseBody = "response_body"
        case responseTruncated = "response_truncated"
        case error
        case createdAt = "created_at"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.httpWorkspaceId = try c.decode(String.self, forKey: .httpWorkspaceId)
        self.requestId = try c.decodeIfPresent(String.self, forKey: .requestId)
        self.environmentId = try c.decodeIfPresent(String.self, forKey: .environmentId)
        self.environmentName = try c.decodeIfPresent(String.self, forKey: .environmentName) ?? ""
        self.method = try c.decodeIfPresent(String.self, forKey: .method) ?? "GET"
        self.resolvedUrl = try c.decodeIfPresent(String.self, forKey: .resolvedUrl) ?? ""
        self.requestHeaders = try c.decodeIfPresent([String: String].self, forKey: .requestHeaders) ?? [:]
        self.requestBody = try c.decodeIfPresent(String.self, forKey: .requestBody) ?? ""
        self.statusCode = try c.decodeIfPresent(Int.self, forKey: .statusCode) ?? 0
        self.statusText = try c.decodeIfPresent(String.self, forKey: .statusText) ?? ""
        self.durationMs = try c.decodeIfPresent(Int.self, forKey: .durationMs) ?? 0
        self.sizeBytes = try c.decodeIfPresent(Int.self, forKey: .sizeBytes) ?? 0
        self.responseHeaders = try c.decodeIfPresent([String: [String]].self, forKey: .responseHeaders) ?? [:]
        self.responseBody = try c.decodeIfPresent(String.self, forKey: .responseBody) ?? ""
        self.responseTruncated = try c.decodeIfPresent(Bool.self, forKey: .responseTruncated) ?? false
        let rawErr = try c.decodeIfPresent(String.self, forKey: .error)
        self.error = rawErr.flatMap { $0.isEmpty ? nil : $0 }
        self.createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt) ?? ""
    }
}

public struct HttpWorkspaceBundle: Codable, Sendable, Equatable {
    public var workspace: HttpWorkspace
    public var environments: [HttpEnvironment]
    public var folders: [HttpFolder]
    public var requests: [HttpRequest]

    public init(
        workspace: HttpWorkspace,
        environments: [HttpEnvironment] = [],
        folders: [HttpFolder] = [],
        requests: [HttpRequest] = []
    ) {
        self.workspace = workspace
        self.environments = environments
        self.folders = folders
        self.requests = requests
    }

    enum CodingKeys: String, CodingKey {
        case workspace, environments, folders, requests
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.workspace = try c.decode(HttpWorkspace.self, forKey: .workspace)
        self.environments = try c.decodeIfPresent([HttpEnvironment].self, forKey: .environments) ?? []
        self.folders = try c.decodeIfPresent([HttpFolder].self, forKey: .folders) ?? []
        self.requests = try c.decodeIfPresent([HttpRequest].self, forKey: .requests) ?? []
    }
}

public struct HttpImportResult: Codable, Sendable, Equatable {
    public var foldersCreated: Int
    public var requestsCreated: Int
    public var environmentsCreated: Int
    public var warnings: [String]

    public init(
        foldersCreated: Int = 0,
        requestsCreated: Int = 0,
        environmentsCreated: Int = 0,
        warnings: [String] = []
    ) {
        self.foldersCreated = foldersCreated
        self.requestsCreated = requestsCreated
        self.environmentsCreated = environmentsCreated
        self.warnings = warnings
    }

    enum CodingKeys: String, CodingKey {
        case foldersCreated = "folders_created"
        case requestsCreated = "requests_created"
        case environmentsCreated = "environments_created"
        case warnings
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.foldersCreated = try c.decodeIfPresent(Int.self, forKey: .foldersCreated) ?? 0
        self.requestsCreated = try c.decodeIfPresent(Int.self, forKey: .requestsCreated) ?? 0
        self.environmentsCreated = try c.decodeIfPresent(Int.self, forKey: .environmentsCreated) ?? 0
        self.warnings = try c.decodeIfPresent([String].self, forKey: .warnings) ?? []
    }
}

public struct HttpWorkspaceList: Codable, Sendable, Equatable {
    public var workspaces: [HttpWorkspace]

    public init(workspaces: [HttpWorkspace] = []) {
        self.workspaces = workspaces
    }

    enum CodingKeys: String, CodingKey { case workspaces }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.workspaces = try c.decodeIfPresent([HttpWorkspace].self, forKey: .workspaces) ?? []
    }
}

public struct HttpExecutionList: Codable, Sendable, Equatable {
    public var executions: [HttpExecution]

    public init(executions: [HttpExecution] = []) {
        self.executions = executions
    }

    enum CodingKeys: String, CodingKey { case executions }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.executions = try c.decodeIfPresent([HttpExecution].self, forKey: .executions) ?? []
    }
}

// MARK: - Mutation Inputs

public struct HttpWorkspaceInput: Codable, Sendable, Equatable {
    public var name: String
    public var description: String
    public var activeEnvironmentId: String?
    public var defaultAuth: HttpAuthConfig
    public var defaultHeaders: [HttpKeyValue]
    public var defaultVars: [HttpEnvVar]
    public var seedEnvironments: Bool?

    public init(
        name: String,
        description: String = "",
        activeEnvironmentId: String? = nil,
        defaultAuth: HttpAuthConfig = .none,
        defaultHeaders: [HttpKeyValue] = [],
        defaultVars: [HttpEnvVar] = [],
        seedEnvironments: Bool? = nil
    ) {
        self.name = name
        self.description = description
        self.activeEnvironmentId = activeEnvironmentId
        self.defaultAuth = defaultAuth
        self.defaultHeaders = defaultHeaders
        self.defaultVars = defaultVars
        self.seedEnvironments = seedEnvironments
    }

    enum CodingKeys: String, CodingKey {
        case name, description
        case activeEnvironmentId = "active_environment_id"
        case defaultAuth = "default_auth"
        case defaultHeaders = "default_headers"
        case defaultVars = "default_vars"
        case seedEnvironments = "seed_environments"
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        try c.encode(description, forKey: .description)
        try c.encode(activeEnvironmentId, forKey: .activeEnvironmentId)
        try c.encode(defaultAuth, forKey: .defaultAuth)
        try c.encode(defaultHeaders, forKey: .defaultHeaders)
        try c.encode(defaultVars, forKey: .defaultVars)
        try c.encodeIfPresent(seedEnvironments, forKey: .seedEnvironments)
    }
}

public struct HttpActiveEnvironmentPatch: Codable, Sendable, Equatable {
    public var environmentId: String?

    public init(environmentId: String?) {
        self.environmentId = environmentId
    }

    enum CodingKeys: String, CodingKey {
        case environmentId = "environment_id"
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        // Always emit "environment_id" (even when nil) so PATCH /active-environment receives non-empty JSON.
        try c.encode(environmentId, forKey: .environmentId)
    }
}

public struct HttpEnvironmentInput: Codable, Sendable, Equatable {
    public var name: String
    public var color: HttpEnvColor
    public var variables: [HttpEnvVar]
    public var sortOrder: Int

    public init(
        name: String,
        color: HttpEnvColor = .green,
        variables: [HttpEnvVar] = [],
        sortOrder: Int = 0
    ) {
        self.name = name
        self.color = color
        self.variables = variables
        self.sortOrder = sortOrder
    }

    enum CodingKeys: String, CodingKey {
        case name, color, variables
        case sortOrder = "sort_order"
    }
}

public struct HttpFolderInput: Codable, Sendable, Equatable {
    public var parentFolderId: String?
    public var name: String
    public var defaultAuth: HttpAuthConfig
    public var defaultHeaders: [HttpKeyValue]
    public var sortOrder: Int

    public init(
        parentFolderId: String? = nil,
        name: String,
        defaultAuth: HttpAuthConfig = .inherit,
        defaultHeaders: [HttpKeyValue] = [],
        sortOrder: Int = 0
    ) {
        self.parentFolderId = parentFolderId
        self.name = name
        self.defaultAuth = defaultAuth
        self.defaultHeaders = defaultHeaders
        self.sortOrder = sortOrder
    }

    enum CodingKeys: String, CodingKey {
        case parentFolderId = "parent_folder_id"
        case name
        case defaultAuth = "default_auth"
        case defaultHeaders = "default_headers"
        case sortOrder = "sort_order"
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(parentFolderId, forKey: .parentFolderId)
        try c.encode(name, forKey: .name)
        try c.encode(defaultAuth, forKey: .defaultAuth)
        try c.encode(defaultHeaders, forKey: .defaultHeaders)
        try c.encode(sortOrder, forKey: .sortOrder)
    }
}

public struct HttpRequestDraftInput: Codable, Sendable, Equatable {
    public var folderId: String?
    public var name: String
    public var method: String
    public var url: String
    public var params: [HttpKeyValue]
    public var headers: [HttpKeyValue]
    public var auth: HttpAuthConfig
    public var bodyMode: HttpBodyMode
    public var body: String
    public var bodyForm: [HttpKeyValue]
    public var timeoutMs: Int
    public var followRedirects: Bool
    public var sortOrder: Int

    public init(
        folderId: String? = nil,
        name: String,
        method: String = "GET",
        url: String = "",
        params: [HttpKeyValue] = [],
        headers: [HttpKeyValue] = [],
        auth: HttpAuthConfig = .inherit,
        bodyMode: HttpBodyMode = .none,
        body: String = "",
        bodyForm: [HttpKeyValue] = [],
        timeoutMs: Int = 30000,
        followRedirects: Bool = true,
        sortOrder: Int = 0
    ) {
        self.folderId = folderId
        self.name = name
        self.method = method
        self.url = url
        self.params = params
        self.headers = headers
        self.auth = auth
        self.bodyMode = bodyMode
        self.body = body
        self.bodyForm = bodyForm
        self.timeoutMs = timeoutMs
        self.followRedirects = followRedirects
        self.sortOrder = sortOrder
    }

    enum CodingKeys: String, CodingKey {
        case folderId = "folder_id"
        case name, method, url, params, headers, auth
        case bodyMode = "body_mode"
        case body
        case bodyForm = "body_form"
        case timeoutMs = "timeout_ms"
        case followRedirects = "follow_redirects"
        case sortOrder = "sort_order"
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(folderId, forKey: .folderId)
        try c.encode(name, forKey: .name)
        try c.encode(method, forKey: .method)
        try c.encode(url, forKey: .url)
        try c.encode(params, forKey: .params)
        try c.encode(headers, forKey: .headers)
        try c.encode(auth, forKey: .auth)
        try c.encode(bodyMode, forKey: .bodyMode)
        try c.encode(body, forKey: .body)
        try c.encode(bodyForm, forKey: .bodyForm)
        try c.encode(timeoutMs, forKey: .timeoutMs)
        try c.encode(followRedirects, forKey: .followRedirects)
        try c.encode(sortOrder, forKey: .sortOrder)
    }
}

public typealias HttpRequestDraft = HttpRequestDraftInput

public struct HttpRunRequestOptions: Codable, Sendable, Equatable {
    public var environmentId: String?
    public var override: HttpRequestDraftInput?

    public init(environmentId: String? = nil, override: HttpRequestDraftInput? = nil) {
        self.environmentId = environmentId
        self.override = override
    }

    enum CodingKeys: String, CodingKey {
        case environmentId = "environment_id"
        case override
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(environmentId, forKey: .environmentId)
        try c.encodeIfPresent(override, forKey: .override)
    }
}

public struct HttpImportFile: Codable, Sendable, Equatable {
    public var path: String
    public var content: String

    public init(path: String, content: String) {
        self.path = path
        self.content = content
    }
}

public struct HttpImportInput: Codable, Sendable, Equatable {
    public var format: HttpImportFormat
    public var content: String?
    public var zipBase64: String?
    public var files: [HttpImportFile]?
    public var folderId: String?

    public init(
        format: HttpImportFormat,
        content: String? = nil,
        zipBase64: String? = nil,
        files: [HttpImportFile]? = nil,
        folderId: String? = nil
    ) {
        self.format = format
        self.content = content
        self.zipBase64 = zipBase64
        self.files = files
        self.folderId = folderId
    }

    enum CodingKeys: String, CodingKey {
        case format, content
        case zipBase64 = "zip_base64"
        case files
        case folderId = "folder_id"
    }
}

// MARK: - API Request Builders

/// Typed endpoints for `/api/v1/http/...` (which live outside `api/openapi.yaml`).
public enum HttpClientAPI {
    public static func listWorkspaces() -> APIRequest<HttpWorkspaceList> {
        APIRequest(
            method: "GET",
            template: "/http/workspaces",
            path: "/api/v1/http/workspaces",
            decode: .json
        )
    }

    public static func getWorkspaceBundle(id: String) -> APIRequest<HttpWorkspaceBundle> {
        APIRequest(
            method: "GET",
            template: "/http/workspaces/{id}",
            path: "/api/v1/http/workspaces/\(APIPath.escape(id))",
            decode: .json
        )
    }

    public static func createWorkspace(_ body: HttpWorkspaceInput) -> APIRequest<HttpWorkspaceBundle> {
        APIRequest(
            method: "POST",
            template: "/http/workspaces",
            path: "/api/v1/http/workspaces",
            body: .json(body),
            decode: .json
        )
    }

    public static func updateWorkspace(id: String, body: HttpWorkspaceInput) -> APIRequest<HttpWorkspace> {
        APIRequest(
            method: "PUT",
            template: "/http/workspaces/{id}",
            path: "/api/v1/http/workspaces/\(APIPath.escape(id))",
            body: .json(body),
            decode: .json
        )
    }

    public static func setActiveEnvironment(workspaceId: String, environmentId: String?) -> APIRequest<HttpWorkspace> {
        APIRequest(
            method: "PATCH",
            template: "/http/workspaces/{id}/active-environment",
            path: "/api/v1/http/workspaces/\(APIPath.escape(workspaceId))/active-environment",
            body: .json(HttpActiveEnvironmentPatch(environmentId: environmentId)),
            decode: .json
        )
    }

    public static func deleteWorkspace(id: String) -> APIRequest<APIEmpty> {
        APIRequest(
            method: "DELETE",
            template: "/http/workspaces/{id}",
            path: "/api/v1/http/workspaces/\(APIPath.escape(id))",
            decode: .empty
        )
    }

    public static func createEnvironment(workspaceId: String, body: HttpEnvironmentInput) -> APIRequest<HttpEnvironment> {
        APIRequest(
            method: "POST",
            template: "/http/workspaces/{id}/environments",
            path: "/api/v1/http/workspaces/\(APIPath.escape(workspaceId))/environments",
            body: .json(body),
            decode: .json
        )
    }

    public static func updateEnvironment(id: String, body: HttpEnvironmentInput) -> APIRequest<HttpEnvironment> {
        APIRequest(
            method: "PUT",
            template: "/http/environments/{id}",
            path: "/api/v1/http/environments/\(APIPath.escape(id))",
            body: .json(body),
            decode: .json
        )
    }

    public static func deleteEnvironment(id: String) -> APIRequest<APIEmpty> {
        APIRequest(
            method: "DELETE",
            template: "/http/environments/{id}",
            path: "/api/v1/http/environments/\(APIPath.escape(id))",
            decode: .empty
        )
    }

    public static func createFolder(workspaceId: String, body: HttpFolderInput) -> APIRequest<HttpFolder> {
        APIRequest(
            method: "POST",
            template: "/http/workspaces/{id}/folders",
            path: "/api/v1/http/workspaces/\(APIPath.escape(workspaceId))/folders",
            body: .json(body),
            decode: .json
        )
    }

    public static func updateFolder(id: String, body: HttpFolderInput) -> APIRequest<HttpFolder> {
        APIRequest(
            method: "PUT",
            template: "/http/folders/{id}",
            path: "/api/v1/http/folders/\(APIPath.escape(id))",
            body: .json(body),
            decode: .json
        )
    }

    public static func deleteFolder(id: String) -> APIRequest<APIEmpty> {
        APIRequest(
            method: "DELETE",
            template: "/http/folders/{id}",
            path: "/api/v1/http/folders/\(APIPath.escape(id))",
            decode: .empty
        )
    }

    public static func createRequest(workspaceId: String, body: HttpRequestDraftInput) -> APIRequest<HttpRequest> {
        APIRequest(
            method: "POST",
            template: "/http/workspaces/{id}/requests",
            path: "/api/v1/http/workspaces/\(APIPath.escape(workspaceId))/requests",
            body: .json(body),
            decode: .json
        )
    }

    public static func updateRequest(id: String, body: HttpRequestDraftInput) -> APIRequest<HttpRequest> {
        APIRequest(
            method: "PUT",
            template: "/http/requests/{id}",
            path: "/api/v1/http/requests/\(APIPath.escape(id))",
            body: .json(body),
            decode: .json
        )
    }

    public static func deleteRequest(id: String) -> APIRequest<APIEmpty> {
        APIRequest(
            method: "DELETE",
            template: "/http/requests/{id}",
            path: "/api/v1/http/requests/\(APIPath.escape(id))",
            decode: .empty
        )
    }

    public static func listRequestExecutions(requestId: String, limit: Int = 25) -> APIRequest<HttpExecutionList> {
        var query: [URLQueryItem] = []
        APIQuery.append(&query, "limit", limit)
        return APIRequest(
            method: "GET",
            template: "/http/requests/{id}/executions",
            path: "/api/v1/http/requests/\(APIPath.escape(requestId))/executions",
            query: query,
            decode: .json
        )
    }

    public static func runRequest(requestId: String, options: HttpRunRequestOptions = HttpRunRequestOptions()) -> APIRequest<HttpExecution> {
        APIRequest(
            method: "POST",
            template: "/http/requests/{id}/run",
            path: "/api/v1/http/requests/\(APIPath.escape(requestId))/run",
            body: .json(options),
            decode: .json
        )
    }

    public static func importCollection(workspaceId: String, body: HttpImportInput) -> APIRequest<HttpImportResult> {
        APIRequest(
            method: "POST",
            template: "/http/workspaces/{id}/import",
            path: "/api/v1/http/workspaces/\(APIPath.escape(workspaceId))/import",
            body: .json(body),
            decode: .json
        )
    }

    // MARK: Cache Invalidation

    public static let workspacesInvalidation = QueryInvalidation(prefixes: [["http", "workspaces"]])

    public static func bundleInvalidation(workspaceId: String) -> QueryInvalidation {
        QueryInvalidation(prefixes: [["http", "workspaces", workspaceId]])
    }

    public static func executionsInvalidation(requestId: String) -> QueryInvalidation {
        QueryInvalidation(prefixes: [["http", "requests", requestId, "executions"]])
    }
}
