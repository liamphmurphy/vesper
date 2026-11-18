import Foundation

// What Quick Capture and the send picker list from the API (desktop/src/native.ts capture-options,
// send-files-get). Parsed leniently: a missing or odd field just drops that entry.

public struct ProjectSummary: Sendable, Equatable, Identifiable {
    public var key: String
    public var name: String
    public var id: String { key }
    public init(key: String, name: String) {
        self.key = key
        self.name = name
    }
}

public struct ChatSummary: Sendable, Equatable, Identifiable {
    public var id: String
    public var title: String
    public init(id: String, title: String) {
        self.id = id
        self.title = title
    }
}

public struct PersonaList: Sendable, Equatable {
    public var personas: [PersonaSummary]
    public var defaultPersonaId: String
    public init(personas: [PersonaSummary] = [], defaultPersonaId: String = "") {
        self.personas = personas
        self.defaultPersonaId = defaultPersonaId
    }
}

public enum CaptureOptions {
    private static func object(_ data: Data) -> Any? { try? JSONSerialization.jsonObject(with: data) }

    /// GET /api/v1/personas → { personas: [{id,name}], default_persona_id }.
    public static func parsePersonas(_ data: Data) -> PersonaList {
        let root = object(data) as? [String: Any] ?? [:]
        let list = (root["personas"] as? [[String: Any]] ?? []).compactMap { p -> PersonaSummary? in
            guard let id = p["id"] as? String, let name = p["name"] as? String,
                  id.range(of: uuidPattern, options: .regularExpression) != nil,
                  !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return PersonaSummary(id: id, name: name)
        }
        let def = root["default_persona_id"] as? String ?? ""
        return PersonaList(personas: list, defaultPersonaId: list.contains { $0.id == def } ? def : "")
    }

    /// GET /api/v1/projects → [{key,name,archived}], archived ones dropped.
    public static func parseProjects(_ data: Data) -> [ProjectSummary] {
        (object(data) as? [[String: Any]] ?? []).compactMap { p in
            guard let key = p["key"] as? String, let name = p["name"] as? String, (p["archived"] as? Bool) != true,
                  key.range(of: #"^[A-Z][A-Z0-9_]{0,31}\z"#, options: .regularExpression) != nil else { return nil }
            return ProjectSummary(key: key, name: name)
        }
    }

    /// GET /api/v1/chats?persona_id=all → { chats: [{id,title}] }, at most `limit`.
    public static func parseChats(_ data: Data, limit: Int = 15) -> [ChatSummary] {
        let root = object(data) as? [String: Any] ?? [:]
        return (root["chats"] as? [[String: Any]] ?? []).compactMap { c in
            guard let id = c["id"] as? String, id.range(of: uuidPattern, options: .regularExpression) != nil else { return nil }
            return ChatSummary(id: id, title: (c["title"] as? String) ?? "")
        }.prefix(limit).map { $0 }
    }
}
