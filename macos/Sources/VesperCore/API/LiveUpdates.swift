import Foundation

/// One server change hint from GET /events: `{"type": "ticket.updated", "ids": [...]}`.
public struct ServerEvent: Sendable, Equatable {
    public var type: String
    public var ids: [String]

    public init(type: String, ids: [String] = []) {
        self.type = type
        self.ids = ids
    }
}

/// Which cached queries a server change hint makes stale: the Swift port of web/lib/live-updates.ts,
/// so native screens refresh on the same hints the web ones do. Keep the two tables in step.
public enum LiveUpdates {
    /// The web's query key roots per hint entity ("ticket" of "ticket.updated").
    static let prefixes: [String: [String]] = [
        "planning": ["planning", "inbox", "bootstrap"],
        "metrics": ["dashboard", "agent-overviews"],
        "ticket": ["planning", "tickets", "boards", "inbox", "bootstrap", "knowledge", "search"],
        "epic": ["projects", "planning", "bootstrap", "tickets", "boards", "epics", "inbox", "search"],
        "activity": ["tickets", "inbox", "bootstrap"],
        "approval": ["tickets", "runs", "chats", "inbox", "bootstrap"],
        "run": ["planning", "runs", "boards", "tickets", "agents", "inbox", "bootstrap", "runner", "search", "dock", "courses"],
        "course": ["courses", "learn"],
        "learning": ["courses", "learn"],
        "agent": ["agents", "bootstrap", "search"],
        "artifact": ["artifacts", "wiki", "knowledge", "inbox", "bootstrap", "search"],
        "knowledge": ["knowledge", "wiki"],
        "project": ["projects", "planning", "bootstrap", "tickets", "boards", "inbox", "search"],
        "inbox": ["inbox", "bootstrap"],
        "chat": ["chats", "canvases", "videos", "audio", "push-requests", "dock"],
        "design": ["canvases"],
        "video": ["videos"],
        "audio": ["audio"],
        "playground": ["playgrounds"],
        "code_review": ["code-review"],
        "push_request": ["push-requests"],
        "pr_feedback": ["tickets", "push-requests", "inbox", "bootstrap"],
        "persona": ["personas", "chats", "dock"],
        "browser_share": ["browser-shares"],
        "custom_app": ["custom-apps"],
        "profile": ["me", "bootstrap"],
        "memory": ["memories"],
        "secret": ["secrets", "chat-models", "image-engine"],
        "api_secret": ["api-secrets"],
        "connector": ["connectors"],
        "repository": ["repositories"],
        "runner": ["runner"],
        "dev_workspace": ["dev-workspace"],
        "space": ["spaces", "chat-spaces"],
        "image_engine": ["image-engine"],
    ]

    /// Hints that change one narrow thing, so they don't also refresh the dashboards.
    static let quiet: Set<String> = [
        "video.updated", "audio.updated", "code_review.updated", "push_request.updated", "pr_feedback.updated",
        "custom_app.updated", "browser_share.updated",
    ]

    /// Web key roots that aren't a literal segment of the API paths they cache, mapped to the
    /// segments that are. A root not listed here is its own segment (`tickets`, `runs`, `inbox`…).
    static let resourceAliases: [String: [String]] = [
        "boards": ["board"],
        "dock": ["persona-dock"],
        "planning": ["planning-sessions"],
        "search": ["search", "chat-search"],
        "chats": ["chats", "chat-search", "highlights", "chat-spaces"],
        "playgrounds": ["playground", "playgrounds"],
        "spaces": ["chat-spaces", "spaces"],
    ]

    /// The web query key roots a hint invalidates (web `invalidatedBy`).
    public static func invalidatedRoots(_ type: String) -> [String] {
        if type == "run.events" { return ["runs"] }
        let entity = String(type.split(separator: ".", maxSplits: 1).first ?? "")
        let keys = prefixes[entity] ?? []
        return quiet.contains(type) ? keys : keys + ["dashboard", "epics", "agent-overviews"]
    }

    /// What a hint makes stale in `QueryStore`: path resources, or exact path prefixes for
    /// `run.events` with run ids (one run's events shouldn't refetch every run).
    public static func invalidation(for event: ServerEvent) -> QueryInvalidation {
        if event.type == "run.events" {
            let ids = event.ids.filter { !$0.isEmpty }
            if !ids.isEmpty { return QueryInvalidation(prefixes: ids.map { ["runs", $0] }) }
        }
        var resources = Set<String>()
        for root in invalidatedRoots(event.type) {
            resources.formUnion(resourceAliases[root] ?? [root])
        }
        return QueryInvalidation(resources: resources)
    }
}

/// A set of cached queries to mark stale: any whose template names one of `resources`, or whose
/// path starts with one of `prefixes`.
public struct QueryInvalidation: Sendable, Equatable {
    public var resources: Set<String>
    public var prefixes: [[String]]

    public init(resources: Set<String> = [], prefixes: [[String]] = []) {
        self.resources = resources
        self.prefixes = prefixes
    }

    public func matches(_ key: QueryKey) -> Bool {
        !key.resources.isDisjoint(with: resources) || prefixes.contains { key.hasPrefix($0) }
    }

    public var isEmpty: Bool { resources.isEmpty && prefixes.isEmpty }
}
