import Foundation

// MARK: - Knowledge Enums

public enum KnowledgeAudience: String, Codable, Sendable, CaseIterable, Hashable {
    case `private` = "private"
    case shared = "shared"
    case agent = "agent"

    public init(from decoder: any Decoder) throws {
        let raw = (try? decoder.singleValueContainer().decode(String.self))?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        self = KnowledgeAudience(rawValue: raw) ?? .private
    }
}

public enum KnowledgePageKind: String, Codable, Sendable, CaseIterable, Hashable {
    case document
    case deck
    case design

    public init(from decoder: any Decoder) throws {
        let raw = (try? decoder.singleValueContainer().decode(String.self))?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        self = KnowledgePageKind(rawValue: raw) ?? .document
    }
}

public enum KnowledgeImportPolicy: String, Codable, Sendable, CaseIterable, Hashable {
    case skip
    case replace
    case keepBoth = "keep_both"
}

// MARK: - Pages, Embeds, Reviews & Versions

public struct KnowledgePageRow: Codable, Sendable, Equatable, Hashable, Identifiable {
    public var id: String
    public var title: String
    public var path: String
    public var audience: KnowledgeAudience
    public var summary: String
    public var properties: [String: JSONValue]
    public var updatedAt: String
    public var versionId: String?
    public var pending: Int
    public var unresolved: Int
    public var kind: KnowledgePageKind
    public var canvasId: String?

    enum CodingKeys: String, CodingKey {
        case id, title, path, audience, summary, properties
        case updatedAt = "updated_at"
        case versionId = "version_id"
        case pending, unresolved, kind
        case canvasId = "canvas_id"
    }

    public init(
        id: String,
        title: String,
        path: String,
        audience: KnowledgeAudience = .private,
        summary: String = "",
        properties: [String: JSONValue] = [:],
        updatedAt: String = "",
        versionId: String? = nil,
        pending: Int = 0,
        unresolved: Int = 0,
        kind: KnowledgePageKind = .document,
        canvasId: String? = nil
    ) {
        self.id = id
        self.title = title
        self.path = path
        self.audience = audience
        self.summary = summary
        self.properties = properties
        self.updatedAt = updatedAt
        self.versionId = versionId
        self.pending = pending
        self.unresolved = unresolved
        self.kind = kind
        self.canvasId = canvasId
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        path = try c.decodeIfPresent(String.self, forKey: .path) ?? ""
        audience = try c.decodeIfPresent(KnowledgeAudience.self, forKey: .audience) ?? .private
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        properties = try c.decodeIfPresent([String: JSONValue].self, forKey: .properties) ?? [:]
        updatedAt = try c.decodeIfPresent(String.self, forKey: .updatedAt) ?? ""
        versionId = try c.decodeIfPresent(String.self, forKey: .versionId)
        pending = try c.decodeIfPresent(Int.self, forKey: .pending) ?? 0
        unresolved = try c.decodeIfPresent(Int.self, forKey: .unresolved) ?? 0
        kind = try c.decodeIfPresent(KnowledgePageKind.self, forKey: .kind) ?? .document
        canvasId = try c.decodeIfPresent(String.self, forKey: .canvasId)
    }
}

public struct KnowledgePageTable: Codable, Sendable, Equatable {
    public var columns: [String]
    public var rows: [KnowledgePageRow]
    public var hasMore: Bool

    enum CodingKeys: String, CodingKey {
        case columns, rows
        case hasMore = "has_more"
    }

    public init(columns: [String] = [], rows: [KnowledgePageRow] = [], hasMore: Bool = false) {
        self.columns = columns
        self.rows = rows
        self.hasMore = hasMore
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        columns = try c.decodeIfPresent([String].self, forKey: .columns) ?? []
        rows = try c.decodeIfPresent([KnowledgePageRow].self, forKey: .rows) ?? []
        hasMore = try c.decodeIfPresent(Bool.self, forKey: .hasMore) ?? false
    }
}

public struct KnowledgePageQuery: Encodable, Sendable, Equatable {
    public var text: String?
    public var folder: String?
    public var tag: String?
    public var audience: KnowledgeAudience?
    public var properties: [String: JSONValue]?
    public var after: String?
    public var before: String?
    public var linksTo: String?
    public var orphans: Bool?
    public var unresolved: Bool?
    public var includeAgent: Bool?
    public var kind: KnowledgePageKind?
    public var limit: Int?
    public var offset: Int?

    public init(
        text: String? = nil,
        folder: String? = nil,
        tag: String? = nil,
        audience: KnowledgeAudience? = nil,
        properties: [String: JSONValue]? = nil,
        after: String? = nil,
        before: String? = nil,
        linksTo: String? = nil,
        orphans: Bool? = nil,
        unresolved: Bool? = nil,
        includeAgent: Bool? = nil,
        kind: KnowledgePageKind? = nil,
        limit: Int? = nil,
        offset: Int? = nil
    ) {
        self.text = text
        self.folder = folder
        self.tag = tag
        self.audience = audience
        self.properties = properties
        self.after = after
        self.before = before
        self.linksTo = linksTo
        self.orphans = orphans
        self.unresolved = unresolved
        self.includeAgent = includeAgent
        self.kind = kind
        self.limit = limit
        self.offset = offset
    }

    enum CodingKeys: String, CodingKey {
        case text, folder, tag, audience, properties, after, before
        case linksTo = "links_to"
        case orphans, unresolved
        case includeAgent = "include_agent"
        case kind, limit, offset
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        if let text, !text.isEmpty { try c.encode(text, forKey: .text) }
        if let folder, !folder.isEmpty { try c.encode(folder, forKey: .folder) }
        if let tag, !tag.isEmpty { try c.encode(tag, forKey: .tag) }
        if let audience { try c.encode(audience, forKey: .audience) }
        if let properties, !properties.isEmpty { try c.encode(properties, forKey: .properties) }
        if let after, !after.isEmpty { try c.encode(after, forKey: .after) }
        if let before, !before.isEmpty { try c.encode(before, forKey: .before) }
        if let linksTo, !linksTo.isEmpty { try c.encode(linksTo, forKey: .linksTo) }
        if orphans == true { try c.encode(true, forKey: .orphans) }
        if unresolved == true { try c.encode(true, forKey: .unresolved) }
        if includeAgent == true { try c.encode(true, forKey: .includeAgent) }
        if let kind { try c.encode(kind, forKey: .kind) }
        if let limit { try c.encode(limit, forKey: .limit) }
        if let offset, offset > 0 { try c.encode(offset, forKey: .offset) }
    }
}

public struct KnowledgeEmbed: Codable, Sendable, Equatable, Hashable {
    public var ref: String
    public var kind: String
    public var title: String?
    public var markdown: String?
    public var url: String?
    public var contentType: String?
    public var available: Bool
    public var data: [String: JSONValue]?

    enum CodingKeys: String, CodingKey {
        case ref, kind, title, markdown, url
        case contentType = "content_type"
        case available, data
    }

    public init(
        ref: String,
        kind: String,
        title: String? = nil,
        markdown: String? = nil,
        url: String? = nil,
        contentType: String? = nil,
        available: Bool = false,
        data: [String: JSONValue]? = nil
    ) {
        self.ref = ref
        self.kind = kind
        self.title = title
        self.markdown = markdown
        self.url = url
        self.contentType = contentType
        self.available = available
        self.data = data
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ref = try c.decode(String.self, forKey: .ref)
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? "unresolved"
        title = try c.decodeIfPresent(String.self, forKey: .title)
        markdown = try c.decodeIfPresent(String.self, forKey: .markdown)
        url = try c.decodeIfPresent(String.self, forKey: .url)
        contentType = try c.decodeIfPresent(String.self, forKey: .contentType)
        available = try c.decodeIfPresent(Bool.self, forKey: .available) ?? false
        data = try c.decodeIfPresent([String: JSONValue].self, forKey: .data)
    }
}

public struct KnowledgePageChange: Codable, Sendable, Equatable {
    public var raw: [String: JSONValue]

    public var kind: String? { raw["kind"]?.stringValue }
    public var before: String? { raw["before"]?.stringValue }
    public var after: String? { raw["after"]?.stringValue }
    public var why: String? { raw["why"]?.stringValue }
    public var state: String? { raw["state"]?.stringValue }
    public var key: String? { raw["key"]?.stringValue }
    public var index: Int? {
        if case .int(let value) = raw["index"] { return value }
        if case .double(let value) = raw["index"] { return Int(value) }
        return nil
    }

    public init(raw: [String: JSONValue] = [:]) {
        self.raw = raw
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        raw = (try? c.decode([String: JSONValue].self)) ?? [:]
    }

    public func encode(to encoder: any Encoder) throws {
        try raw.encode(to: encoder)
    }
}

public struct KnowledgeReview: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var state: String
    public var reviewState: String?
    public var changes: [KnowledgePageChange]
    public var authorId: String
    public var createdAt: String

    enum CodingKeys: String, CodingKey {
        case id, state
        case reviewState = "review_state"
        case changes
        case authorId = "author_id"
        case createdAt = "created_at"
    }

    public init(
        id: String,
        state: String,
        reviewState: String? = nil,
        changes: [KnowledgePageChange] = [],
        authorId: String = "",
        createdAt: String = ""
    ) {
        self.id = id
        self.state = state
        self.reviewState = reviewState
        self.changes = changes
        self.authorId = authorId
        self.createdAt = createdAt
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        state = try c.decodeIfPresent(String.self, forKey: .state) ?? ""
        reviewState = try c.decodeIfPresent(String.self, forKey: .reviewState)
        changes = try c.decodeIfPresent([KnowledgePageChange].self, forKey: .changes) ?? []
        authorId = try c.decodeIfPresent(String.self, forKey: .authorId) ?? ""
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt) ?? ""
    }
}

public struct KnowledgeVersion: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var seq: Int
    public var label: String
    public var note: String
    public var authorType: String
    public var authorId: String
    public var createdAt: String

    enum CodingKeys: String, CodingKey {
        case id, seq, label, note
        case authorType = "author_type"
        case authorId = "author_id"
        case createdAt = "created_at"
    }

    public init(
        id: String,
        seq: Int,
        label: String = "",
        note: String = "",
        authorType: String = "user",
        authorId: String = "",
        createdAt: String = ""
    ) {
        self.id = id
        self.seq = seq
        self.label = label
        self.note = note
        self.authorType = authorType
        self.authorId = authorId
        self.createdAt = createdAt
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        seq = try c.decodeIfPresent(Int.self, forKey: .seq) ?? 0
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? ""
        note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
        authorType = try c.decodeIfPresent(String.self, forKey: .authorType) ?? "user"
        authorId = try c.decodeIfPresent(String.self, forKey: .authorId) ?? ""
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt) ?? ""
    }
}

public struct KnowledgePage: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var title: String
    public var path: String?
    public var audience: KnowledgeAudience
    public var kind: KnowledgePageKind
    public var canvasId: String?
    public var bodyMd: String?
    public var versionId: String
    public var seq: Int
    public var properties: [String: JSONValue]
    public var direct: Bool
    public var paused: Bool
    public var chatId: String?
    public var url: String
    public var embeds: [KnowledgeEmbed]
    public var reviews: [KnowledgeReview]
    public var versions: [KnowledgeVersion]

    enum CodingKeys: String, CodingKey {
        case id, title, path, audience, kind
        case canvasId = "canvas_id"
        case bodyMd = "body_md"
        case versionId = "version_id"
        case seq, properties, direct, paused
        case chatId = "chat_id"
        case url, embeds, reviews, versions
    }

    public init(
        id: String,
        title: String,
        path: String? = nil,
        audience: KnowledgeAudience = .private,
        kind: KnowledgePageKind = .document,
        canvasId: String? = nil,
        bodyMd: String? = nil,
        versionId: String = "",
        seq: Int = 1,
        properties: [String: JSONValue] = [:],
        direct: Bool = false,
        paused: Bool = false,
        chatId: String? = nil,
        url: String = "",
        embeds: [KnowledgeEmbed] = [],
        reviews: [KnowledgeReview] = [],
        versions: [KnowledgeVersion] = []
    ) {
        self.id = id
        self.title = title
        self.path = path
        self.audience = audience
        self.kind = kind
        self.canvasId = canvasId
        self.bodyMd = bodyMd
        self.versionId = versionId
        self.seq = seq
        self.properties = properties
        self.direct = direct
        self.paused = paused
        self.chatId = chatId
        self.url = url
        self.embeds = embeds
        self.reviews = reviews
        self.versions = versions
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        path = try c.decodeIfPresent(String.self, forKey: .path)
        audience = try c.decodeIfPresent(KnowledgeAudience.self, forKey: .audience) ?? .private
        kind = try c.decodeIfPresent(KnowledgePageKind.self, forKey: .kind) ?? .document
        canvasId = try c.decodeIfPresent(String.self, forKey: .canvasId)
        bodyMd = try c.decodeIfPresent(String.self, forKey: .bodyMd)
        versionId = try c.decodeIfPresent(String.self, forKey: .versionId) ?? ""
        seq = try c.decodeIfPresent(Int.self, forKey: .seq) ?? 0
        properties = try c.decodeIfPresent([String: JSONValue].self, forKey: .properties) ?? [:]
        direct = try c.decodeIfPresent(Bool.self, forKey: .direct) ?? false
        paused = try c.decodeIfPresent(Bool.self, forKey: .paused) ?? false
        chatId = try c.decodeIfPresent(String.self, forKey: .chatId)
        url = try c.decodeIfPresent(String.self, forKey: .url) ?? ""
        embeds = try c.decodeIfPresent([KnowledgeEmbed].self, forKey: .embeds) ?? []
        reviews = try c.decodeIfPresent([KnowledgeReview].self, forKey: .reviews) ?? []
        versions = try c.decodeIfPresent([KnowledgeVersion].self, forKey: .versions) ?? []
    }
}

public struct KnowledgePageInput: Encodable, Sendable, Equatable {
    public var title: String?
    public var path: String?
    public var bodyMd: String?
    public var properties: [String: JSONValue]?
    public var audience: String?
    public var baseVersionId: String?
    public var note: String?
    public var template: String?

    enum CodingKeys: String, CodingKey {
        case title, path
        case bodyMd = "body_md"
        case properties, audience
        case baseVersionId = "base_version_id"
        case note, template
    }

    public init(
        title: String? = nil,
        path: String? = nil,
        bodyMd: String? = nil,
        properties: [String: JSONValue]? = nil,
        audience: String? = nil,
        baseVersionId: String? = nil,
        note: String? = nil,
        template: String? = nil
    ) {
        self.title = title
        self.path = path
        self.bodyMd = bodyMd
        self.properties = properties
        self.audience = audience
        self.baseVersionId = baseVersionId
        self.note = note
        self.template = template
    }
}

public struct KnowledgeReviewDecision: Codable, Sendable, Equatable {
    public var index: Int
    public var accept: Bool
    public var reason: String?

    public init(index: Int, accept: Bool, reason: String? = nil) {
        self.index = index
        self.accept = accept
        self.reason = reason
    }
}

// MARK: - Network Graph

public struct KnowledgeNetworkNode: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var title: String
    public var path: String
    public var audience: KnowledgeAudience

    enum CodingKeys: String, CodingKey {
        case id, title, path, audience
    }

    public init(id: String, title: String, path: String, audience: KnowledgeAudience = .private) {
        self.id = id
        self.title = title
        self.path = path
        self.audience = audience
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        path = try c.decodeIfPresent(String.self, forKey: .path) ?? ""
        audience = try c.decodeIfPresent(KnowledgeAudience.self, forKey: .audience) ?? .private
    }
}

public struct KnowledgeNetworkLink: Codable, Sendable, Equatable, Hashable {
    public var source: String
    public var target: String?
    public var unresolved: String?

    public init(source: String, target: String? = nil, unresolved: String? = nil) {
        self.source = source
        self.target = target
        self.unresolved = unresolved
    }
}

public struct KnowledgeNetwork: Codable, Sendable, Equatable {
    public var nodes: [KnowledgeNetworkNode]
    public var links: [KnowledgeNetworkLink]

    enum CodingKeys: String, CodingKey {
        case nodes, links
    }

    public init(nodes: [KnowledgeNetworkNode] = [], links: [KnowledgeNetworkLink] = []) {
        self.nodes = nodes
        self.links = links
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        nodes = try c.decodeIfPresent([KnowledgeNetworkNode].self, forKey: .nodes) ?? []
        links = try c.decodeIfPresent([KnowledgeNetworkLink].self, forKey: .links) ?? []
    }
}

// MARK: - Vault Imports

public struct KnowledgeVaultEntry: Codable, Sendable, Equatable {
    public var source: String
    public var path: String
    public var kind: String
    public var title: String?
    public var renamed: Bool?
    public var conflict: Bool?
    public var duplicate: Bool?
    public var originalTitle: String?
    public var existingId: String?
    public var tags: [String]?
    public var daily: Bool?
    public var error: String?
    public var unsupported: Bool?

    enum CodingKeys: String, CodingKey {
        case source, path, kind, title, renamed, conflict, duplicate
        case originalTitle = "original_title"
        case existingId = "existing_id"
        case tags, daily, error, unsupported
    }

    public init(
        source: String,
        path: String,
        kind: String,
        title: String? = nil,
        renamed: Bool? = nil,
        conflict: Bool? = nil,
        duplicate: Bool? = nil,
        originalTitle: String? = nil,
        existingId: String? = nil,
        tags: [String]? = nil,
        daily: Bool? = nil,
        error: String? = nil,
        unsupported: Bool? = nil
    ) {
        self.source = source
        self.path = path
        self.kind = kind
        self.title = title
        self.renamed = renamed
        self.conflict = conflict
        self.duplicate = duplicate
        self.originalTitle = originalTitle
        self.existingId = existingId
        self.tags = tags
        self.daily = daily
        self.error = error
        self.unsupported = unsupported
    }
}

public struct KnowledgeImportResult: Codable, Sendable, Equatable {
    public var source: String
    public var status: String
    public var reason: String

    enum CodingKeys: String, CodingKey {
        case source, status, reason
    }

    public init(source: String, status: String, reason: String = "") {
        self.source = source
        self.status = status
        self.reason = reason
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        source = try c.decodeIfPresent(String.self, forKey: .source) ?? ""
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? ""
        reason = try c.decodeIfPresent(String.self, forKey: .reason) ?? ""
    }
}

public struct KnowledgeVaultPlan: Codable, Sendable, Equatable {
    public var entries: [KnowledgeVaultEntry]
    public var notes: Int
    public var attachments: Int
    public var resolved: Int
    public var unresolved: [String]
    public var folders: [String]
    public var tags: [String]

    enum CodingKeys: String, CodingKey {
        case entries, notes, attachments, resolved, unresolved, folders, tags
    }

    public init(
        entries: [KnowledgeVaultEntry] = [],
        notes: Int = 0,
        attachments: Int = 0,
        resolved: Int = 0,
        unresolved: [String] = [],
        folders: [String] = [],
        tags: [String] = []
    ) {
        self.entries = entries
        self.notes = notes
        self.attachments = attachments
        self.resolved = resolved
        self.unresolved = unresolved
        self.folders = folders
        self.tags = tags
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        entries = try c.decodeIfPresent([KnowledgeVaultEntry].self, forKey: .entries) ?? []
        notes = try c.decodeIfPresent(Int.self, forKey: .notes) ?? 0
        attachments = try c.decodeIfPresent(Int.self, forKey: .attachments) ?? 0
        resolved = try c.decodeIfPresent(Int.self, forKey: .resolved) ?? 0
        unresolved = try c.decodeIfPresent([String].self, forKey: .unresolved) ?? []
        folders = try c.decodeIfPresent([String].self, forKey: .folders) ?? []
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
    }
}

public struct KnowledgeImportJob: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var state: String
    public var folder: String
    public var policy: String?
    public var plan: KnowledgeVaultPlan?
    public var report: [KnowledgeImportResult]?
    public var filesDone: Int
    public var error: String?
    public var createdAt: String
    public var updatedAt: String

    enum CodingKeys: String, CodingKey {
        case id, state, folder, policy, plan, report
        case filesDone = "files_done"
        case error
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    public init(
        id: String,
        state: String = "",
        folder: String = "",
        policy: String? = nil,
        plan: KnowledgeVaultPlan? = nil,
        report: [KnowledgeImportResult]? = nil,
        filesDone: Int = 0,
        error: String? = nil,
        createdAt: String = "",
        updatedAt: String = ""
    ) {
        self.id = id
        self.state = state
        self.folder = folder
        self.policy = policy
        self.plan = plan
        self.report = report
        self.filesDone = filesDone
        self.error = error
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        state = try c.decodeIfPresent(String.self, forKey: .state) ?? ""
        folder = try c.decodeIfPresent(String.self, forKey: .folder) ?? ""
        policy = try c.decodeIfPresent(String.self, forKey: .policy)
        plan = try c.decodeIfPresent(KnowledgeVaultPlan.self, forKey: .plan)
        report = try c.decodeIfPresent([KnowledgeImportResult].self, forKey: .report)
        filesDone = try c.decodeIfPresent(Int.self, forKey: .filesDone) ?? 0
        error = try c.decodeIfPresent(String.self, forKey: .error)
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt) ?? ""
        updatedAt = try c.decodeIfPresent(String.self, forKey: .updatedAt) ?? ""
    }
}

// MARK: - Supporting Responses & Request Bodies

public struct KnowledgeDeleteResponse: Codable, Sendable, Equatable {
    public var deleted: [String]
}

public struct KnowledgeMoveFolderResponse: Codable, Sendable, Equatable {
    public var moved: [String]
}

public struct KnowledgeTemplatesResponse: Codable, Sendable, Equatable {
    public var templates: [String: String]
}

public struct KnowledgeImportsListResponse: Codable, Sendable, Equatable {
    public var imports: [KnowledgeImportJob]
}

public struct KnowledgeAssetSuggestion: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var title: String
    public var ref: String
    public var contentType: String

    enum CodingKeys: String, CodingKey {
        case id, title, ref
        case contentType = "content_type"
    }
}

public struct KnowledgeAssetsResponse: Codable, Sendable, Equatable {
    public var images: [KnowledgeAssetSuggestion]
}

public struct KnowledgeUploadedAsset: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var ref: String
    public var url: String
    public var filename: String?
    public var contentType: String?

    enum CodingKeys: String, CodingKey {
        case id, ref, url, filename
        case contentType = "content_type"
    }
}

public struct KnowledgeLegacyResponse: Codable, Sendable, Equatable {
    public var id: String
    public var url: String
}

private struct KnowledgeDailyBody: Encodable, Sendable {
    var date: String?
    var folder: String?
    var template: String?
}

private struct KnowledgeFolderMoveBody: Encodable, Sendable {
    var from: String
    var to: String
    var agent: Bool
}

private struct KnowledgeFolderDeleteBody: Encodable, Sendable {
    var folder: String
    var agent: Bool
}

private struct KnowledgeControlsBody: Encodable, Sendable {
    var direct: Bool
    var paused: Bool
}

private struct KnowledgeChatBody: Encodable, Sendable {
    var chatId: String
    enum CodingKeys: String, CodingKey { case chatId = "chat_id" }
}

private struct KnowledgeReviewResolveBody: Encodable, Sendable {
    var decisions: [KnowledgeReviewDecision]
}

private struct KnowledgeFileCaptureBody: Encodable, Sendable {
    var folder: String?
    var merge: String?
}

private struct KnowledgeFromCanvasBody: Encodable, Sendable {
    var chatId: String
    var canvasId: String
    var folder: String?
    enum CodingKeys: String, CodingKey {
        case chatId = "chat_id"
        case canvasId = "canvas_id"
        case folder
    }
}

private struct KnowledgeConfirmImportBody: Encodable, Sendable {
    var policy: KnowledgeImportPolicy
}

// MARK: - Requests & Cache Invalidation

public enum KnowledgeAPI {
    public static let invalidation = QueryInvalidation(prefixes: [["knowledge"], ["wiki"], ["artifacts"]])

    /// GET /api/v1/knowledge/pages — query-string based so `QueryStore` caches distinct filters cleanly.
    public static func listPages(
        q: String? = nil,
        tag: String? = nil,
        folder: String? = nil,
        audience: KnowledgeAudience? = nil,
        includeAgent: Bool = false,
        orphans: Bool = false,
        unresolved: Bool = false,
        kind: KnowledgePageKind? = nil,
        limit: Int? = nil,
        offset: Int? = nil
    ) -> APIRequest<KnowledgePageTable> {
        var query: [URLQueryItem] = []
        if let q, !q.isEmpty { APIQuery.append(&query, "q", q) }
        if let tag, !tag.isEmpty { APIQuery.append(&query, "tag", tag) }
        if let folder, !folder.isEmpty { APIQuery.append(&query, "folder", folder) }
        if let audience { APIQuery.append(&query, "audience", audience.rawValue) }
        if includeAgent { APIQuery.append(&query, "include_agent", true) }
        if orphans { APIQuery.append(&query, "orphans", true) }
        if unresolved { APIQuery.append(&query, "unresolved", true) }
        if let kind { APIQuery.append(&query, "kind", kind.rawValue) }
        if let limit { APIQuery.append(&query, "limit", limit) }
        if let offset, offset > 0 { APIQuery.append(&query, "offset", offset) }
        return APIRequest(
            method: "GET",
            template: "/knowledge/pages",
            path: "/api/v1/knowledge/pages",
            query: query,
            decode: .json
        )
    }

    /// POST /api/v1/knowledge/query — use via `client.send(...)` when filtering by `properties` or `linksTo`.
    public static func queryPages(_ body: KnowledgePageQuery) -> APIRequest<KnowledgePageTable> {
        APIRequest(
            method: "POST",
            template: "/knowledge/query",
            path: "/api/v1/knowledge/query",
            body: .json(body),
            decode: .json
        )
    }

    /// Fetches every explorer page across 200-row pages (matching web `useAllPages`).
    public static func fetchAllPages(includeAgent: Bool, using client: APIClient) async throws -> [KnowledgePageRow] {
        var out: [KnowledgePageRow] = []
        var offset = 0
        while offset <= 20_000 {
            let table = try await client.send(listPages(
                audience: includeAgent ? .agent : nil,
                includeAgent: includeAgent,
                limit: 200,
                offset: offset
            ))
            out.append(contentsOf: table.rows)
            if !table.hasMore || table.rows.isEmpty { break }
            offset += 200
        }
        return out
    }

    public static func getPage(id: String) -> APIRequest<KnowledgePage> {
        APIRequest(
            method: "GET",
            template: "/knowledge/pages/{id}",
            path: "/api/v1/knowledge/pages/\(APIPath.escape(id))",
            decode: .json
        )
    }

    public static func createPage(_ body: KnowledgePageInput) -> APIRequest<KnowledgePage> {
        APIRequest(
            method: "POST",
            template: "/knowledge/pages",
            path: "/api/v1/knowledge/pages",
            body: .json(body),
            decode: .json
        )
    }

    public static func savePage(id: String, body: KnowledgePageInput) -> APIRequest<KnowledgePage> {
        APIRequest(
            method: "PUT",
            template: "/knowledge/pages/{id}",
            path: "/api/v1/knowledge/pages/\(APIPath.escape(id))",
            body: .json(body),
            decode: .json
        )
    }

    public static func updatePage(id: String, body: KnowledgePageInput) -> APIRequest<KnowledgePage> {
        savePage(id: id, body: body)
    }

    public static func movePage(id: String, title: String? = nil, path: String) -> APIRequest<KnowledgePage> {
        savePage(id: id, body: KnowledgePageInput(title: title, path: path))
    }

    public static func deletePage(id: String) -> APIRequest<KnowledgeDeleteResponse> {
        APIRequest(
            method: "DELETE",
            template: "/knowledge/pages/{id}",
            path: "/api/v1/knowledge/pages/\(APIPath.escape(id))",
            decode: .json
        )
    }

    public static func captureNote(_ body: KnowledgePageInput) -> APIRequest<KnowledgePage> {
        APIRequest(
            method: "POST",
            template: "/knowledge/capture",
            path: "/api/v1/knowledge/capture",
            body: .json(body),
            decode: .json
        )
    }

    public static func dailyNote(date: String? = nil, folder: String? = nil, template: String? = nil) -> APIRequest<KnowledgePage> {
        APIRequest(
            method: "POST",
            template: "/knowledge/daily",
            path: "/api/v1/knowledge/daily",
            body: .json(KnowledgeDailyBody(date: date, folder: folder, template: template)),
            decode: .json
        )
    }

    public static func updatePageControls(id: String, direct: Bool, paused: Bool) -> APIRequest<KnowledgePage> {
        APIRequest(
            method: "PUT",
            template: "/knowledge/pages/{id}/controls",
            path: "/api/v1/knowledge/pages/\(APIPath.escape(id))/controls",
            body: .json(KnowledgeControlsBody(direct: direct, paused: paused)),
            decode: .json
        )
    }

    public static func attachChat(id: String, chatId: String) -> APIRequest<KnowledgePage> {
        APIRequest(
            method: "PUT",
            template: "/knowledge/pages/{id}/chat",
            path: "/api/v1/knowledge/pages/\(APIPath.escape(id))/chat",
            body: .json(KnowledgeChatBody(chatId: chatId)),
            decode: .json
        )
    }

    public static func resolveReview(id: String, versionId: String, decisions: [KnowledgeReviewDecision]) -> APIRequest<KnowledgePage> {
        APIRequest(
            method: "POST",
            template: "/knowledge/pages/{id}/reviews/{version}/resolve",
            path: "/api/v1/knowledge/pages/\(APIPath.escape(id))/reviews/\(APIPath.escape(versionId))/resolve",
            body: .json(KnowledgeReviewResolveBody(decisions: decisions)),
            decode: .json
        )
    }

    public static func restoreVersion(id: String, versionId: String) -> APIRequest<KnowledgePage> {
        APIRequest(
            method: "POST",
            template: "/knowledge/pages/{id}/restore/{version}",
            path: "/api/v1/knowledge/pages/\(APIPath.escape(id))/restore/\(APIPath.escape(versionId))",
            decode: .json
        )
    }

    public static func fileCapture(id: String, folder: String? = nil, merge: String? = nil) -> APIRequest<KnowledgePage> {
        APIRequest(
            method: "POST",
            template: "/knowledge/pages/{id}/file",
            path: "/api/v1/knowledge/pages/\(APIPath.escape(id))/file",
            body: .json(KnowledgeFileCaptureBody(folder: folder, merge: merge)),
            decode: .json
        )
    }

    public static func moveCanvasToPage(chatId: String, canvasId: String, folder: String? = nil) -> APIRequest<KnowledgePage> {
        APIRequest(
            method: "POST",
            template: "/knowledge/pages/from-canvas",
            path: "/api/v1/knowledge/pages/from-canvas",
            body: .json(KnowledgeFromCanvasBody(chatId: chatId, canvasId: canvasId, folder: folder)),
            decode: .json
        )
    }

    public static func moveFolder(from: String, to: String, agent: Bool) -> APIRequest<KnowledgeMoveFolderResponse> {
        APIRequest(
            method: "POST",
            template: "/knowledge/folders/move",
            path: "/api/v1/knowledge/folders/move",
            body: .json(KnowledgeFolderMoveBody(from: from, to: to, agent: agent)),
            decode: .json
        )
    }

    public static func deleteFolder(folder: String, agent: Bool) -> APIRequest<KnowledgeDeleteResponse> {
        APIRequest(
            method: "POST",
            template: "/knowledge/folders/delete",
            path: "/api/v1/knowledge/folders/delete",
            body: .json(KnowledgeFolderDeleteBody(folder: folder, agent: agent)),
            decode: .json
        )
    }

    public static func getSavedQuery(id: String) -> APIRequest<KnowledgePageTable> {
        APIRequest(
            method: "GET",
            template: "/knowledge/pages/{id}/query",
            path: "/api/v1/knowledge/pages/\(APIPath.escape(id))/query",
            decode: .json
        )
    }

    public static func getNetwork(includeAgent: Bool = false) -> APIRequest<KnowledgeNetwork> {
        var query: [URLQueryItem] = []
        if includeAgent { APIQuery.append(&query, "include_agent", true) }
        return APIRequest(
            method: "GET",
            template: "/knowledge/network",
            path: "/api/v1/knowledge/network",
            query: query,
            decode: .json
        )
    }

    public static func getTemplates() -> APIRequest<KnowledgeTemplatesResponse> {
        APIRequest(
            method: "GET",
            template: "/knowledge/templates",
            path: "/api/v1/knowledge/templates",
            decode: .json
        )
    }

    public static func listAssets(q: String? = nil) -> APIRequest<KnowledgeAssetsResponse> {
        var query: [URLQueryItem] = []
        if let q, !q.isEmpty { APIQuery.append(&query, "q", q) }
        return APIRequest(
            method: "GET",
            template: "/knowledge/assets",
            path: "/api/v1/knowledge/assets",
            query: query,
            decode: .json
        )
    }

    public static func uploadAsset(data: Data, filename: String) -> APIRequest<KnowledgeUploadedAsset> {
        var query: [URLQueryItem] = []
        if !filename.isEmpty { APIQuery.append(&query, "filename", filename) }
        return APIRequest(
            method: "POST",
            template: "/knowledge/assets",
            path: "/api/v1/knowledge/assets",
            query: query,
            body: .raw(data, contentType: "application/octet-stream"),
            decode: .json
        )
    }

    public static func resolveLegacy(path: String) -> APIRequest<KnowledgeLegacyResponse> {
        var query: [URLQueryItem] = []
        APIQuery.append(&query, "path", path)
        return APIRequest(
            method: "GET",
            template: "/knowledge/legacy",
            path: "/api/v1/knowledge/legacy",
            query: query,
            decode: .json
        )
    }

    public static func listImports() -> APIRequest<KnowledgeImportsListResponse> {
        APIRequest(
            method: "GET",
            template: "/knowledge/imports",
            path: "/api/v1/knowledge/imports",
            decode: .json
        )
    }

    public static func getImport(id: String) -> APIRequest<KnowledgeImportJob> {
        APIRequest(
            method: "GET",
            template: "/knowledge/imports/{id}",
            path: "/api/v1/knowledge/imports/\(APIPath.escape(id))",
            decode: .json
        )
    }

    public static func uploadVault(zipData: Data, folder: String = "") -> APIRequest<KnowledgeImportJob> {
        var query: [URLQueryItem] = []
        if !folder.isEmpty { APIQuery.append(&query, "folder", folder) }
        return APIRequest(
            method: "POST",
            template: "/knowledge/imports",
            path: "/api/v1/knowledge/imports",
            query: query,
            body: .raw(zipData, contentType: "application/zip"),
            decode: .json
        )
    }

    public static func confirmImport(id: String, policy: KnowledgeImportPolicy) -> APIRequest<KnowledgeImportJob> {
        APIRequest(
            method: "POST",
            template: "/knowledge/imports/{id}/confirm",
            path: "/api/v1/knowledge/imports/\(APIPath.escape(id))/confirm",
            body: .json(KnowledgeConfirmImportBody(policy: policy)),
            decode: .json
        )
    }

    public static func cancelImport(id: String) -> APIRequest<KnowledgeImportJob> {
        APIRequest(
            method: "POST",
            template: "/knowledge/imports/{id}/cancel",
            path: "/api/v1/knowledge/imports/\(APIPath.escape(id))/cancel",
            decode: .json
        )
    }

    public static func undoImport(id: String) -> APIRequest<KnowledgeImportJob> {
        APIRequest(
            method: "POST",
            template: "/knowledge/imports/{id}/undo",
            path: "/api/v1/knowledge/imports/\(APIPath.escape(id))/undo",
            decode: .json
        )
    }
}
